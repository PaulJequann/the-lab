#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["bcrypt>=4"]
# ///
"""Generate a bcrypt hash for use as the ArgoCD admin_password_hash.

Usage:
    scripts/bcrypt-hash.py                  # prompts (no echo)
    scripts/bcrypt-hash.py --plaintext PW   # pass directly (beware shell history)
    echo -n "$PW" | scripts/bcrypt-hash.py -
"""
import argparse
import getpass
import sys

import bcrypt


def main() -> int:
    parser = argparse.ArgumentParser(description="Generate a $2a$ bcrypt hash.")
    parser.add_argument("--plaintext", help="password (omit to prompt securely)")
    parser.add_argument("--rounds", type=int, default=10, help="bcrypt cost (default 10)")
    parser.add_argument("stdin", nargs="?", help="pass '-' to read from stdin")
    args = parser.parse_args()

    if args.stdin == "-":
        password = sys.stdin.read().rstrip("\n")
    elif args.plaintext is not None:
        password = args.plaintext
    else:
        password = getpass.getpass("Password: ")
        confirm = getpass.getpass("Confirm:  ")
        if password != confirm:
            print("passwords do not match", file=sys.stderr)
            return 1

    if not password:
        print("empty password", file=sys.stderr)
        return 1

    salt = bcrypt.gensalt(rounds=args.rounds, prefix=b"2a")
    print(bcrypt.hashpw(password.encode("utf-8"), salt).decode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
