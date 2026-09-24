# Arena Suite — OpenCode v2 setup

This project deliberately does not hard-code an Astra provider/model ID.

Select the Astra model already available in OpenCode. Once the exact provider/model ID is verified, optionally pin it in project config.

## Prerequisites

Verify:

```bash
xcode-select -p
xcodebuild -version
swift --version
xcrun swift-format --version
```

## XcodeBuildMCP

Preferred installation:

```bash
brew tap getsentry/xcodebuildmcp
brew install xcodebuildmcp
xcodebuildmcp --help
```

Configure it project-locally as an MCP server using:

```bash
xcodebuildmcp mcp
```

## Context7

Configure Context7 as a remote project MCP server:

```text
https://mcp.context7.com/mcp
```

Do not rely on the failed `@upstash/context7-opencode` plugin.

Authenticate through the OpenCode-supported MCP OAuth flow if required.

## Required repository layout

```text
Arena-Suite-Master-Plan-v2.md
AGENTS.md
FIRST-PROMPT.md
SETUP.md
opencode.jsonc
.swift-format

.opencode/
  agents/
    reviewer.md
  skills/
    arena-suite/
      SKILL.md
```

## Start

1. Launch OpenCode in the repository.
2. Select Astra.
3. Confirm XcodeBuildMCP and Context7 are connected.
4. Confirm the Arena Suite skill is discoverable.
5. Confirm the reviewer subagent is discoverable.
6. Paste `FIRST-PROMPT.md`.

Do not begin with “build Arena Suite.”
