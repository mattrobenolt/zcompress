"""Tag-scoped EC2 lifecycle operations."""

import json
import logging
import os
import subprocess
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import boto3

from ec2bench.config import Config

logger = logging.getLogger(__name__)

ACTIVE = ("pending", "running", "stopping", "stopped")


def tags(instance: dict[str, Any]) -> dict[str, str]:
    return {item["Key"]: item["Value"] for item in instance.get("Tags", [])}


def expiry(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value)
    except ValueError:
        return None
    return parsed.astimezone(UTC) if parsed.tzinfo else None


def reap_candidates(instances: list[dict[str, Any]], now: datetime) -> list[str]:
    return [
        instance["InstanceId"]
        for instance in instances
        if (expires := expiry(tags(instance).get("ExpiresAt"))) is None or expires <= now
    ]


class Fleet:
    def __init__(self, config: Config, client: Any = None) -> None:
        self.config = config
        self.client = client or boto3.Session(
            profile_name=os.environ.get("AWS_PROFILE", config.project["profile"]),
            region_name=config.project["region"],
        ).client("ec2")

    def instances(self) -> list[dict[str, Any]]:
        pages = self.client.get_paginator("describe_instances").paginate(
            Filters=[
                {"Name": "tag:Project", "Values": [self.config.project["name"]]},
                {"Name": "instance-state-name", "Values": list(ACTIVE)},
            ]
        )
        return [
            instance
            for page in pages
            for reservation in page["Reservations"]
            for instance in reservation["Instances"]
        ]

    def selected(self, names: list[str]) -> list[dict[str, Any]]:
        self.config.select(names)
        return [instance for instance in self.instances() if tags(instance).get("Target") in names]

    def one(self, target: str) -> dict[str, Any]:
        found = self.selected([target])
        if len(found) != 1:
            raise ValueError(f"Expected one instance for {target}, found {len(found)}")
        return found[0]

    def outputs(self) -> dict[str, Any]:
        output = subprocess.run(
            ["tofu", f"-chdir={self.config.tofu_dir}", "output", "-json"],
            cwd=self.config.root,
            check=True,
            capture_output=True,
            text=True,
            timeout=60,
        )
        return {key: value["value"] for key, value in json.loads(output.stdout).items()}

    def key_path(self, outputs: dict[str, Any]) -> Path:
        path = Path(outputs[self.config.project.get("key_output", "key_file")])
        return self.config.tofu_dir / path

    def launch(
        self, target: str, ttl: str, size: str | None, outputs: dict[str, Any]
    ) -> dict[str, Any]:
        lifetime = self.config.ttl(ttl)
        self.config.select([target])
        found = self.selected([target])
        if found:
            winner = self.converge(target, found)
            if winner["State"]["Name"] not in {"pending", "running"}:
                raise ValueError(f"{target} is stopped or stopping; terminate it before up")
            return winner
        target_config = self.config.targets[target]
        instance_type = target_config["instance_type"]
        if size:
            if not size.replace("-", "").isalnum():
                raise ValueError("Invalid instance size")
            instance_type = instance_type.split(".")[0] + "." + size
        values = {
            "Project": self.config.project["name"],
            "ManagedBy": "ec2bench",
            "Name": f"{self.config.project['name']}-{target}",
            "Target": target,
            "ExpiresAt": (datetime.now(UTC) + lifetime).strftime("%Y-%m-%dT%H:%M:%SZ"),
            "Owner": self.config.fleet["default_owner"],
        }
        response = self.client.run_instances(
            MinCount=1,
            MaxCount=1,
            InstanceType=instance_type,
            LaunchTemplate={
                "LaunchTemplateId": outputs[
                    self.config.project.get("templates_output", "launch_template_ids")
                ][target_config["arch"]],
                "Version": "$Latest",
            },
            TagSpecifications=[
                {
                    "ResourceType": resource,
                    "Tags": [
                        {"Key": key, "Value": value}
                        for key, value in values.items()
                        if resource == "instance" or key in {"Project", "ManagedBy"}
                    ],
                }
                for resource in ("instance", "volume", "network-interface")
            ],
        )
        launched = response["Instances"][0]
        discovered = {instance["InstanceId"]: instance for instance in self.selected([target])}
        discovered.setdefault(launched["InstanceId"], launched)
        return self.converge(target, list(discovered.values()))

    def converge(self, target: str, instances: list[dict[str, Any]]) -> dict[str, Any]:
        winner = min(
            instances, key=lambda instance: (instance["LaunchTime"], instance["InstanceId"])
        )
        losers = [
            instance["InstanceId"]
            for instance in instances
            if instance["InstanceId"] != winner["InstanceId"]
        ]
        if losers:
            logger.warning(
                "Duplicate target %s: keep %s and terminate %s",
                target,
                winner["InstanceId"],
                ", ".join(losers),
            )
            self.terminate(losers)
        return winner

    def wait_running(self, instance_id: str) -> dict[str, Any]:
        self.client.get_waiter("instance_running").wait(
            InstanceIds=[instance_id], WaiterConfig={"Delay": 5, "MaxAttempts": 120}
        )
        response = self.client.describe_instances(InstanceIds=[instance_id])
        return response["Reservations"][0]["Instances"][0]

    def terminate(self, ids: list[str]) -> None:
        if ids:
            self.client.terminate_instances(InstanceIds=ids)

    def extend(self, names: list[str], ttl: str) -> None:
        lifetime = self.config.ttl(ttl)
        ids = [instance["InstanceId"] for instance in self.selected(names)]
        value = (datetime.now(UTC) + lifetime).strftime("%Y-%m-%dT%H:%M:%SZ")
        if ids:
            self.client.create_tags(Resources=ids, Tags=[{"Key": "ExpiresAt", "Value": value}])

    def reap(self) -> list[str]:
        ids = reap_candidates(self.instances(), datetime.now(UTC))
        self.terminate(ids)
        return ids
