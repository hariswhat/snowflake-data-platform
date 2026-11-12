"""Split a Snowflake script into statements: semicolons inside comments,
quoted strings and $$ blocks do not end a statement. Comments are dropped."""

from __future__ import annotations


def split(script: str) -> list[str]:
    out, buf, i, n = [], [], 0, len(script)
    while i < n:
        two = script[i : i + 2]
        c = script[i]
        if two == "--":
            j = script.find("\n", i)
            i = n if j < 0 else j
            continue
        if two == "/*":
            j = script.find("*/", i + 2)
            i = n if j < 0 else j + 2
            continue
        if two == "$$":
            j = script.find("$$", i + 2)
            if j < 0:
                raise ValueError("unterminated $$ block")
            buf.append(script[i : j + 2])
            i = j + 2
            continue
        if c == "'":
            j = i + 1
            while j < n:
                if script[j] == "'" and script[j + 1 : j + 2] == "'":
                    j += 2
                    continue
                if script[j] == "'":
                    break
                j += 1
            buf.append(script[i : j + 1])
            i = j + 1
            continue
        if c == ";":
            stmt = "".join(buf).strip()
            if stmt:
                out.append(stmt)
            buf = []
            i += 1
            continue
        buf.append(c)
        i += 1
    stmt = "".join(buf).strip()
    if stmt:
        out.append(stmt)
    return out
