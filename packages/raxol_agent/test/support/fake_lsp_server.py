#!/usr/bin/env python3
"""A minimal but real language server, for exercising the LSP client.

Speaks the actual wire protocol (Content-Length framed JSON-RPC over stdio)
so the tests drive the same code path a real server would. It is not a mock:
nothing is stubbed inside the agent, and the transport, framing, request/
response correlation, and unsolicited notifications are all genuine.

Its language is deliberately trivial:

  * a line containing BROKEN is an error diagnostic
  * a line containing SUSPECT is a warning
  * `def <name>` declares a symbol
  * definition/references resolve by exact word match across the document

Behaviour switches for tests, via argv:

  --no-diagnostics   never publish diagnostics (exercises the await timeout)
  --rename-refuses   answer rename with null (a symbol that cannot be renamed)
  --rename-escapes   answer rename with an edit to /etc/passwd (containment)
  --slow-init N      wait N seconds before answering initialize
"""

import json
import os
import re
import sys
import time

ARGS = set(sys.argv[1:])


def arg_value(flag, default):
    argv = sys.argv[1:]
    if flag in argv:
        index = argv.index(flag)
        if index + 1 < len(argv):
            return argv[index + 1]
    return default


documents = {}


def read_message():
    headers = {}
    while True:
        line = sys.stdin.buffer.readline()
        if not line:
            return None
        line = line.decode("utf-8", "replace").strip()
        if line == "":
            break
        if ": " in line:
            key, value = line.split(": ", 1)
            headers[key] = value
    length = int(headers.get("Content-Length", 0))
    if length == 0:
        return None
    body = sys.stdin.buffer.read(length)
    return json.loads(body.decode("utf-8"))


def send(payload):
    body = json.dumps(payload).encode("utf-8")
    try:
        sys.stdout.buffer.write(b"Content-Length: %d\r\n\r\n" % len(body))
        sys.stdout.buffer.write(body)
        sys.stdout.buffer.flush()
    except BrokenPipeError:
        # The client closed the port. That is how a session ends, not an
        # error; exiting quietly keeps it out of the test output.
        os._exit(0)


def respond(request_id, result):
    send({"jsonrpc": "2.0", "id": request_id, "result": result})


def notify(method, params):
    send({"jsonrpc": "2.0", "method": method, "params": params})


def u16(text, index):
    """Python codepoint index -> UTF-16 code unit index.

    LSP counts `character` in UTF-16 code units, so a real server reports 7
    for a name that follows an emoji, not 6. Python string indices are
    codepoints, so every offset leaving this process is converted -- without
    it the fixture would be lenient in exactly the way that hides the bug.
    """
    return len(text[:index].encode("utf-16-le")) // 2


def codepoint(text, unit):
    """UTF-16 code unit index -> Python codepoint index."""
    return len(text.encode("utf-16-le")[: unit * 2].decode("utf-16-le", "ignore"))


def position(line, character):
    return {"line": line, "character": character}


def span(line, start, end):
    """A range from UTF-16 code unit offsets."""
    return {"start": position(line, start), "end": position(line, end)}


def span_in(text, line, start, end):
    """A range from Python codepoint offsets into `text`."""
    return span(line, u16(text, start), u16(text, end))


def publish_diagnostics(uri):
    if "--no-diagnostics" in ARGS:
        return

    diagnostics = []
    for number, text in enumerate(documents.get(uri, "").split("\n")):
        if "BROKEN" in text:
            column = text.index("BROKEN")
            diagnostics.append(
                {
                    "range": span_in(text, number, column, column + len("BROKEN")),
                    "severity": 1,
                    "message": "this line is broken",
                    "source": "fake-lsp",
                }
            )
        elif "SUSPECT" in text:
            column = text.index("SUSPECT")
            diagnostics.append(
                {
                    "range": span_in(text, number, column, column + len("SUSPECT")),
                    "severity": 2,
                    "message": "this line is suspect",
                    "source": "fake-lsp",
                }
            )

    notify(
        "textDocument/publishDiagnostics",
        {"uri": uri, "diagnostics": diagnostics},
    )


def word_at(uri, line, character):
    lines = documents.get(uri, "").split("\n")
    if line >= len(lines):
        return None
    text = lines[line]
    index = codepoint(text, character)
    for match in re.finditer(r"[A-Za-z_][A-Za-z0-9_]*", text):
        if match.start() <= index < match.end():
            return match.group(0)
    return None


def occurrences(uri, word):
    found = []
    for number, text in enumerate(documents.get(uri, "").split("\n")):
        for match in re.finditer(r"\b%s\b" % re.escape(word), text):
            found.append(
                {"uri": uri, "range": span_in(text, number, match.start(), match.end())}
            )
    return found


def handle(message):
    method = message.get("method")
    request_id = message.get("id")
    params = message.get("params") or {}

    if method == "initialize":
        delay = arg_value("--slow-init", None)
        if delay:
            time.sleep(float(delay))
        respond(
            request_id,
            {
                "capabilities": {
                    "textDocumentSync": 1,
                    "documentSymbolProvider": True,
                    "definitionProvider": True,
                    "referencesProvider": True,
                    "hoverProvider": True,
                    "renameProvider": True,
                    "workspace": {
                        "fileOperations": {
                            "willRename": {"filters": [{"pattern": {"glob": "**/*"}}]}
                        }
                    },
                },
                "serverInfo": {"name": "fake-lsp", "version": "1"},
            },
        )
        return

    if method == "textDocument/didOpen":
        document = params["textDocument"]
        documents[document["uri"]] = document.get("text", "")
        publish_diagnostics(document["uri"])
        return

    if method == "textDocument/didChange":
        uri = params["textDocument"]["uri"]
        changes = params.get("contentChanges") or []
        if changes:
            documents[uri] = changes[-1].get("text", "")
        publish_diagnostics(uri)
        return

    if method == "textDocument/didClose":
        documents.pop(params["textDocument"]["uri"], None)
        return

    if method == "textDocument/documentSymbol":
        uri = params["textDocument"]["uri"]
        symbols = []
        for number, text in enumerate(documents.get(uri, "").split("\n")):
            match = re.match(r"\s*def\s+([A-Za-z_][A-Za-z0-9_]*)", text)
            if match:
                symbols.append(
                    {
                        "name": match.group(1),
                        "kind": 12,
                        "range": span_in(text, number, 0, len(text)),
                        "selectionRange": span_in(text, number, match.start(1), match.end(1)),
                        "children": [],
                    }
                )
        respond(request_id, symbols)
        return

    if method == "textDocument/definition":
        uri = params["textDocument"]["uri"]
        pos = params["position"]
        word = word_at(uri, pos["line"], pos["character"])
        if not word:
            respond(request_id, None)
            return
        for number, text in enumerate(documents.get(uri, "").split("\n")):
            match = re.match(r"\s*def\s+(%s)\b" % re.escape(word), text)
            if match:
                # A LocationLink, to exercise the shape most servers send.
                respond(
                    request_id,
                    [
                        {
                            "targetUri": uri,
                            "targetRange": span_in(text, number, 0, len(text)),
                            "targetSelectionRange": span_in(
                                text, number, match.start(1), match.end(1)
                            ),
                        }
                    ],
                )
                return
        respond(request_id, None)
        return

    if method == "textDocument/references":
        uri = params["textDocument"]["uri"]
        pos = params["position"]
        word = word_at(uri, pos["line"], pos["character"])
        respond(request_id, occurrences(uri, word) if word else [])
        return

    if method == "textDocument/hover":
        uri = params["textDocument"]["uri"]
        pos = params["position"]
        word = word_at(uri, pos["line"], pos["character"])
        if word:
            respond(
                request_id,
                {"contents": {"kind": "markdown", "value": "`%s` is a symbol" % word}},
            )
        else:
            respond(request_id, None)
        return

    if method == "textDocument/rename":
        if "--rename-refuses" in ARGS:
            respond(request_id, None)
            return

        uri = params["textDocument"]["uri"]
        pos = params["position"]
        new_name = params["newName"]
        word = word_at(uri, pos["line"], pos["character"])
        if not word:
            respond(request_id, None)
            return

        target = "file:///etc/passwd" if "--rename-escapes" in ARGS else uri
        edits = [
            {"range": place["range"], "newText": new_name}
            for place in occurrences(uri, word)
        ]
        respond(request_id, {"changes": {target: edits}})
        return

    if method == "workspace/willRenameFiles":
        files = params.get("files") or []
        if not files:
            respond(request_id, None)
            return
        old_uri = files[0]["oldUri"]
        new_name = files[0]["newUri"].rsplit("/", 1)[-1].rsplit(".", 1)[0]
        respond(
            request_id,
            {
                "documentChanges": [
                    {
                        "textDocument": {"uri": old_uri, "version": 1},
                        "edits": [
                            {"range": span(0, 0, 0), "newText": "# moved to %s\n" % new_name}
                        ],
                    }
                ]
            },
        )
        return

    if method == "shutdown":
        respond(request_id, None)
        return

    if method == "exit":
        sys.exit(0)

    # An unknown request still needs an answer or the client waits forever.
    if request_id is not None:
        respond(request_id, None)


def main():
    while True:
        try:
            message = read_message()
        except Exception:
            return
        if message is None:
            return
        handle(message)


if __name__ == "__main__":
    main()
