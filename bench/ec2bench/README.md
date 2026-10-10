# ec2bench

`ec2bench` manages a tag-scoped EC2 fleet. A project adapter supplies benchmark commands.
The package contains no benchmark-specific build or analysis code.

## Adoption procedure

1. Copy `ec2bench/` into your Python project.
2. Copy the infrastructure pattern into your repository.
3. Add `boto3`, `click`, and `rich` to your dependencies.
4. Register `bench = "ec2bench.cli:main"` as a project script.
5. Create `bench.toml` at the repository root.
6. Set the project name and AWS profile to your project values.
7. Set the infrastructure path and output names to match your OpenTofu stack.
8. Add each target instance type and architecture.
9. Add the results directory and cache directory to `.gitignore`.
10. Add the private key and OpenTofu state files to `.gitignore`.
11. Apply the infrastructure with OpenTofu.
12. Run `bench up <target>`.

The default paths require these ignore patterns:

```gitignore
/bench-results/
/.bench-cache/
/infra/base/bench.pem
**/.terraform/
**/terraform.tfstate*
```

## Configuration

```toml
[project]
name = "example-bench"
region = "us-west-2"
profile = "example-bench"
adapter = "example_bench"
image_version = "1"
tofu_dir = "infra/base"
key_output = "key_file"
templates_output = "launch_template_ids"
ssh_user = "root"
results_dir = "bench-results"
cache_dir = ".bench-cache"

[fleet]
default_ttl = "4h"
max_ttl = "12h"
default_owner = "agent"

[targets.intel]
instance_type = "c7i.xlarge"
arch = "x86_64"
```

The architecture is `x86_64` or `arm64`. Unknown configuration keys belong to the adapter.
The `AWS_PROFILE` environment variable overrides the configured profile.
The path and output settings above show their defaults.
Relative directory paths start at the repository root.
A relative path from the key output starts at `tofu_dir`.
The template output maps architecture names to launch template IDs.
The image exposes its version in `/etc/bench-image`.

`up` and `extend` reject TTL values above `fleet.max_ttl`. Its default is 12 hours.
The default TTL must not exceed this limit.

## Adapter interface

The configured adapter exports `register(group)`. This function attaches Click commands to the group.
Each command receives `Config` through `click.pass_obj`.

```python
import click
from ec2bench.config import Config


def register(group: click.Group) -> None:
    @group.command()
    @click.pass_obj
    def run(config: Config) -> None:
        click.echo(config.root)
```

`Fleet` manages instances through project tags. `Box` provides SSH commands and file transfers.
`parallel` returns independent results and errors for each task.
`facts.collect(box, config.results_dir)` caches facts by instance ID under `results_dir/.facts/`.
Each remote probe is optional. A failed probe produces a null value and an entry in `errors`.
An adapter can require specific facts before its benchmark starts.

`isolation.isolate` reserves the final physical core. It restores cpuset properties when its context exits.
`isolation.run_isolated` executes a command through `bench.slice`, outside the restricted SSH slice.
The SSH user must have permission to manage system units and `/run/`.
The library does not add `sudo` automatically.

```python
from ec2bench.isolation import isolate, run_isolated, stop_isolated

with isolate(box, facts["topology"]) as cpu:
    try:
        run_isolated(
            box,
            cpu,
            ["/opt/benchmark", "--samples", "5"],
            unit=f"{run_id}-r0",
            output=f"/tmp/{run_id}.out",
            error=f"/tmp/{run_id}.stderr",
        )
    finally:
        stop_isolated(box, run_id)
```

The execution helper forwards remote stderr on command failure.
Its default timeout is 600 seconds. The service runtime limit is 60 seconds shorter.
The adapter must stop its units before the isolation context exits.
The adapter must use a safe run ID for unit names and shell commands.

`runs.create_run(..., results_dir=config.results_dir)` records source provenance and instance IDs.
Adapters must use `config.cache_dir` and `config.results_dir` for their local artifacts.
Adapter-specific keys such as `remote_dir` do not require generic configuration changes.

## Safety

Every launch request tags these resource types with `Project` and `ManagedBy=ec2bench`:

- `instance`
- `volume`
- `network-interface`

Instances also receive these tags:

- `Name`
- `Target`
- `ExpiresAt`
- `Owner`

`ExpiresAt` uses RFC 3339 UTC with a `Z` suffix.
The image must enforce this tag with its shutdown timer.
The launch template must set shutdown behavior to `terminate`.
An external reaper must enforce the earlier of `ExpiresAt` and `LaunchTime + 24h`.
The external reaper remains necessary when first-boot setup fails or the harness disappears.

The harness calls `reap` at the start of `up` and the fastmem `run` command.
The harness reaper treats absent or malformed expiration tags as expired.
A failed EC2 or image readiness wait triggers termination of that instance.
A failed target does not prevent measurements on other targets with `run --up`.

An atomic directory claim prevents concurrent CPU isolation on one box.
Active `ec2bench-run-*` units also cause a busy-box error.
A hard controller failure can leave `/run/ec2bench-isolation.lock` behind.
The next run refuses that box. It does not share its CPU.

### Stale claim recovery

1. Check that no other harness process owns the box.
2. Stop the abandoned `ec2bench-run-*` services.
3. Restore the original cpuset properties, or reboot the instance.
4. Remove `/run/ec2bench-isolation.lock` if it remains after recovery.

## Current limits

Concurrent `up` commands for the same target are unsupported. EC2 tags do not provide an atomic launch claim.
After launch, the harness selects the earliest instance and terminates duplicates that it discovers.
The lowest instance ID breaks ties. Eventual consistency can delay duplicate discovery.
The `ls` command flags duplicate targets. Separate processes can operate on different targets.

The harness requires launch templates. It does not adopt direct `aws_instance` resources from OpenTofu state.
A different stack path or output name needs configuration only.
Other deployment models can require infrastructure changes.

These features are unsupported:

- Placement-group selection through the harness.
- A second instance per target, such as a separate load client.
- A private-IP accessor or private-only SSH transport.
- Non-systemd CPU isolation.
- Automatic privilege escalation for a non-root SSH user.

## Adapter

The zcompress adapter (`zcompress_bench`) is documented in `../README.md`.
