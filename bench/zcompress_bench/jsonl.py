"""Schema-v1 measurement records: one JSONL file per (arm, round).

A file is a meta record, one sample record per (case, implementation, sample)
measurement, and an end record. Every fleet driver — the Zig binary
(bench/zig/bench_zcompress.zig), the Go klauspost driver, the C
libdeflate/zlib-ng drivers, and the C++ google/snappy driver — emits this
exact schema over the exact committed corpus. The parser is the contract: a
record that does not validate fails the round.
"""

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

SCHEMA = 1
ARMS = ("zc", "klauspost", "libdeflate", "zlibng", "googlesnappy", "zstd-c")
CODECS = ("flate", "gzip", "zlib", "snappy", "zstd")
DIRECTIONS = ("compress", "decompress")
SHAPES = ("text", "random", "html", "rle", "mixed")
SIZES = (32768, 65536)
SHA256_HEX = r"^[0-9a-f]{64}$"


class Record(BaseModel):
    model_config = ConfigDict(allow_inf_nan=False, extra="forbid", strict=True)


class Meta(Record):
    type: Literal["meta"]
    schema_version: Literal[1] = Field(alias="schema")
    arm: str = Field(min_length=1)
    tool: str = Field(min_length=1)
    rev: str = Field(min_length=1)
    toolchain: str = Field(min_length=1)
    target: str = Field(min_length=1)
    cpu: str = Field(min_length=1)
    optimize: str = Field(min_length=1)
    suite: Literal["standard", "quick"]
    seed: int = Field(ge=0)
    samples: int = Field(gt=0)
    sample_ms: int = Field(gt=0, le=60000)
    impls: list[str] = Field(min_length=1)
    corpus: dict[str, str]

    @field_validator("schema_version", mode="before")
    @classmethod
    def strict_schema(cls, value: Any) -> int:
        if type(value) is not int or value != SCHEMA:
            raise ValueError("Schema must be the integer 1")
        return value

    @model_validator(mode="after")
    def check_meta(self) -> Meta:
        import re

        if len(self.impls) != len(set(self.impls)):
            raise ValueError("Duplicate implementation in meta")
        expected = {f"{shape}-{size}" for shape in SHAPES for size in SIZES}
        if set(self.corpus) != expected:
            raise ValueError("Meta corpus must hash the ten raw corpus files")
        for name, digest in self.corpus.items():
            if not re.fullmatch(SHA256_HEX, digest):
                raise ValueError(f"Corpus hash for {name} is not SHA-256 hex")
        return self


class Sample(Record):
    type: Literal["sample"]
    case: str
    codec: Literal["flate", "gzip", "zlib", "snappy", "zstd"]
    direction: Literal["compress", "decompress"]
    shape: Literal["text", "random", "html", "rle", "mixed"]
    size: int
    impl: str = Field(min_length=1)
    sample: int = Field(ge=0)
    iters: int = Field(gt=0)
    ns: int = Field(gt=0)
    out_len: int = Field(ge=0)

    @model_validator(mode="after")
    def check_case(self) -> Sample:
        if self.size not in SIZES:
            raise ValueError("Size is outside the corpus")
        if self.case != f"{self.codec}/{self.direction}/{self.shape}/{self.size}":
            raise ValueError("Case ID disagrees with the sample fields")
        if self.direction == "decompress" and self.out_len != self.size:
            raise ValueError("A decompress row must reproduce the raw size")
        return self


class End(Record):
    type: Literal["end"]
    cases: int = Field(ge=0)
    elapsed_ns: int = Field(ge=0)


@dataclass
class Measurement:
    meta: dict[str, Any]
    samples: list[dict[str, Any]]
    end: dict[str, Any]


def applicable(meta: Meta, sample: Sample) -> list[str]:
    """The implementations that must report this case: the std rows have no snappy."""
    return [impl for impl in meta.impls if not (impl == "std" and sample.codec == "snappy")]


def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"Duplicate JSON key: {key}")
        result[key] = value
    return result


def check_corpus(measurement: Measurement, corpus: dict[str, str] | None) -> None:
    if corpus is not None and measurement.meta["corpus"] != corpus:
        raise ValueError("Measurement corpus hashes disagree with the committed corpus")


def parse(path: Path, *, corpus: dict[str, str] | None = None) -> Measurement:
    try:
        measurement = parse_text(path.read_text())
        check_corpus(measurement, corpus)
    except ValueError as error:
        raise ValueError(f"{path}: {error}") from error
    else:
        return measurement


def parse_text(text: str) -> Measurement:
    records = [
        json.loads(line, object_pairs_hook=unique_object)
        for line in text.splitlines()
        if line.strip()
    ]
    if any(not isinstance(record, dict) for record in records):
        raise ValueError("JSONL records must be objects")
    first = records[0] if records else {}
    if first.get("type") != "meta" or first.get("schema") != SCHEMA:
        raise ValueError("Expected a schema-v1 meta record")
    if records[-1].get("type") != "end":
        raise ValueError("Incomplete measurement: no end record")
    meta = Meta.model_validate(records[0])
    end = End.model_validate(records[-1])
    samples = [Sample.model_validate(record) for record in records[1:-1]]
    validate_samples(meta, samples, end)
    return Measurement(
        meta.model_dump(by_alias=True),
        [sample.model_dump() for sample in samples],
        end.model_dump(),
    )


def validate_samples(meta: Meta, samples: list[Sample], end: End) -> None:
    seen = set()
    cases: dict[str, Sample] = {}
    for sample in samples:
        if sample.impl not in meta.impls:
            raise ValueError(f"Sample implementation {sample.impl} is outside the meta list")
        if sample.impl == "std" and sample.codec == "snappy":
            raise ValueError("The std implementation has no snappy row")
        key = (sample.case, sample.impl, sample.sample)
        if key in seen:
            raise ValueError(f"Duplicate sample {key}")
        seen.add(key)
        if sample.case in cases:
            first = cases[sample.case]
            fields = ("codec", "direction", "shape", "size")
            if any(getattr(first, field) != getattr(sample, field) for field in fields):
                raise ValueError(f"Case metadata changed: {sample.case}")
        cases[sample.case] = sample
    if end.cases != len({(sample.codec, sample.shape, sample.size) for sample in cases.values()}):
        raise ValueError("End case count does not match samples")
    expected = {
        (case, impl, index)
        for case, sample in cases.items()
        for impl in applicable(meta, sample)
        for index in range(meta.samples)
    }
    if seen != expected:
        raise ValueError("Sample set does not match the declared implementations and sample count")
