from __future__ import annotations

from abc import ABCMeta, abstractmethod
from ast import literal_eval
from pathlib import Path
from string import Template
from subprocess import getoutput
from typing import TYPE_CHECKING, Any
from urllib.parse import quote

from jinja2.environment import Environment
from jinja2.ext import Extension
from copier_templates_extensions import ContextHook

if TYPE_CHECKING:
    from collections.abc import Iterable

    from extensions.make_context import MakeContextDict


LATEST_PYTHON_VERSION: tuple[int, int] = (3, 12)
LATEST_PYPY_VERSION: tuple[int, int] = (3, 10)
PYTHON_VERSION_AHEAD: tuple[int, int] = (3, LATEST_PYTHON_VERSION[1] + 1)


COVERAGE_URL: Template = Template(
    "https://coverage-badge.samuelcolvin.workers.dev/redirect/${github}/${repo}",
)

REPO_URL: Template = Template(
    "https://github.com/${github}/${repo}",
)

DOCS_URL: Template = Template(
    "https://${rtd}.readthedocs.io/en/latest/",
)

PYPI_URL: Template = Template(
    "https://pypi.org/project/${pypi_project}/",
)

TIDELIFT_URL: Template = Template(
    "https://tidelift.com/subscription/pkg/pypi-${pypi_project}"
    "?utm_source=pypi-${pypi_project}",
)

SKELETON_URL: Template = Template(
    "https://github.com/${skeleton}",
)

RAW_SKELETON_URL: Template = Template(
    "https://raw.githubusercontent.com/${skeleton}",
)

SKELETON_REV: Template = Template(
    "https://github.com/${skeleton}/tree/${skeleton_ref}",
)

SKELETON_NOTICE: Template = Template(
    "This ${scope} was generated from ${snref}.\n"
    "Instead of changing this particular file, you might want to alter the template:\n"
    "${srev}/${path}"
)

SKELETON_NOTICE_PATHLESS: Template = Template(
    "This ${scope} was generated from a template file.\n"
    "Instead of changing this particular file, you might want to alter the template "
    "somewhere in:\n"
    "${srev}"
)


def skeleton_notice(
    path: str | None, snref: str, srev: str, scope: str = "file"
) -> str:
    if path is None:
        return SKELETON_NOTICE_PATHLESS.substitute(
            scope=scope,
            srev=srev,
        )
    return SKELETON_NOTICE.substitute(
        scope=scope,
        snref=snref,
        srev=srev,
        path=quote(path or ""),
    )


class InplaceContextHook(ContextHook, metaclass=ABCMeta):
    update = False

    def hook(self, context: dict[str, Any]) -> dict[str, Any]:
        bash: MakeContextDict = context["make_context"]
        return self._hook(context, bash) or context

    @abstractmethod
    def _hook(self, context: dict[str, Any], bash: MakeContextDict, /) -> None: ...


# Assume the tester is in the skeleton repository
GH_SKELETON_REPO_NAME = getoutput(
    "gh repo view --json nameWithOwner --jq .nameWithOwner"
)


class SkeletonContextHook(InplaceContextHook):
    def _hook(self, context: dict[str, Any], bash: MakeContextDict, /) -> None:
        context[bash["skeleton"]] = (
            GH_SKELETON_REPO_NAME
            if context["ctt"]
            else context["_src_path"].lstrip("gh://")
        )
        context[bash["skeleton_url"]] = SKELETON_URL.substitute(context)
        context[bash["raw_skeleton_url"]] = RAW_SKELETON_URL.substitute(context)
        context[bash["skeleton_ref"]] = context[bash["sref"]] = context[
            "_copier_answers"
        ]["_commit"]
        context[bash["skeleton_rev"]] = context[bash["srev"]] = SKELETON_REV.substitute(
            context
        )
        context[bash["skeleton_and_ref"]] = context[bash["snref"]] = "@".join(
            (context["skeleton"], context["skeleton_ref"])
        )


class FilterExtension(Extension):
    def __init__(self, environment: Environment) -> None:
        super().__init__(environment)
        # Usage: {{path...|skeleton_notice(snref=snref, srev=srev)}}
        environment.filters["skeleton_notice"] = skeleton_notice
        environment.globals["literal_eval"] = literal_eval


class ProjectURLContextHook(InplaceContextHook):
    def _hook(self, context: dict[str, Any], bash: MakeContextDict, /) -> None:
        context[bash["repo_url"]] = REPO_URL.substitute(context)
        context[bash["coverage_url"]] = COVERAGE_URL.substitute(context)
        context[bash["docs_url"]] = DOCS_URL.substitute(context)
        context[bash["pypi_url"]] = PYPI_URL.substitute(context)
        context[bash["tidelift_url"]] = TIDELIFT_URL.substitute(context)


def _generate_pythons(
    python_string: str,
    *,
    pypy: bool = True,
) -> Iterable[tuple[str, int]]:
    (major, minor) = tuple(map(int, python_string.split(".")))
    yield (str(major), minor)
    pypy and (major, minor) <= LATEST_PYPY_VERSION and (yield (f"pypy{major}", minor))
    while (major, minor) < LATEST_PYTHON_VERSION:
        minor += 1
        yield (str(major), minor)
        pypy and (major, minor) <= LATEST_PYPY_VERSION and (
            yield (f"pypy{major}", minor)
        )


class PythonVersionsContextHook(InplaceContextHook):
    def _hook(self, context: dict[str, Any], bash: MakeContextDict, /) -> None:
        context[bash["latest_python"]] = ".".join(map(str, LATEST_PYTHON_VERSION))
        context[bash["python_ahead"]] = ".".join(map(str, PYTHON_VERSION_AHEAD))
        context[bash["pythons"]] = ", ".join(
            f"{major}.{minor}".join('""')
            for major, minor in sorted(
                _generate_pythons(
                    context[bash["python"]],
                    pypy=context[bash["pypy"]],
                )
            )
        )


class VisibilityContextHook(InplaceContextHook):
    def _hook(self, context: dict[str, Any], bash: MakeContextDict, /) -> None:
        context[bash["public"]] = context[bash["visibility"]] == "public"
        context[bash["private"]] = not context["public"]


class TemplateContextHook(InplaceContextHook):
    def preprocess(
        self,
        source: str,
        name: str | None,
        filename: str | None = None,
    ) -> str:
        self.filename = filename and Path(*Path(filename).parts[3:]).as_posix()
        return source

    def _hook(self, context: dict[str, Any], _bash: MakeContextDict, /) -> None:
        context["_origin"] = self.filename


class GitContextHook(InplaceContextHook):
    def _hook(self, context: dict[str, Any], bash: MakeContextDict, /) -> None:
        context[bash["git_username"]] = getoutput("git config user.name")
        context[bash["git_email"]] = getoutput("git config user.email")


class SelfContextHook(InplaceContextHook):
    def _hook(self, context: dict[str, Any], _bash: MakeContextDict, /) -> None:
        context["context"] = context.copy()
