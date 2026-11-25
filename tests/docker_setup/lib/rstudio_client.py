#!/usr/bin/env python3
"""
rstudio_client.py: signs in to RStudio Server the way a browser does

PURPOSE
    The tests must prove two things through the real RStudio Server:
      1. its sign-in page accepts the right password and refuses a wrong one;
      2. an R session that RStudio starts for "rstudio" creates files with the
         requested user and group numbers.
    This script does what the browser does: it loads the sign-in page, encrypts user
    name and password with the public key the server offers, posts the form, and then
    talks to the session with the same calls the RStudio page uses.

WHEN IT RUNS
    run-tests.sh copies it into the running test container and starts it there with
    "docker exec". It uses only Python's standard library.

HOW TO CALL IT
    The password is read from the first line of standard input, so it never appears in
    a command line.

    rstudio_client.py signin URL USER
        Prints ACCEPTED or REFUSED. Exit code 0 for accepted, 1 for refused.

    rstudio_client.py run URL USER R_FILE
        Signs in, starts an R session, waits for the R prompt and lets the session run
        source("R_FILE"). Exit code 0 when the session took the command, 1 when the
        sign-in was refused, 2 for any other problem.

WHAT IT CHANGES
    Nothing by itself. The R file given to "run" does whatever it contains, as the user
    "rstudio", inside the RStudio session.

WHAT IT NEVER TOUCHES
    Files, accounts and settings of the container. It only talks to RStudio Server over
    its web address, as a browser would, and keeps the password in memory only.

EXIT CODE 2 means the script itself could not do its work (server not reachable,
unexpected answer). The reason is printed.
"""

import base64
import http.cookiejar
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


class NoRedirect(urllib.request.HTTPRedirectHandler):
    """Keeps the answer "302, go to page X" visible. Where RStudio sends the browser
    after the sign-in form tells us whether the password was accepted."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


class Client:
    def __init__(self, base_url):
        self.base_url = base_url.rstrip("/")
        # The cookie jar keeps the cookies RStudio sets, as a browser would.
        self.cookies = http.cookiejar.CookieJar()
        self.opener = urllib.request.build_opener(
            urllib.request.HTTPCookieProcessor(self.cookies), NoRedirect
        )
        self.client_id = None

    def request(self, path, data=None, headers=None):
        """One HTTP request. Returns (status code, headers, body text)."""
        req = urllib.request.Request(self.base_url + path, data=data, headers=headers or {})
        try:
            with self.opener.open(req, timeout=60) as answer:
                return answer.status, answer.headers, answer.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as error:
            # 302 (redirect) and error codes arrive here; they are answers, too.
            return error.code, error.headers, error.read().decode("utf-8", "replace")

    def cookie(self, name):
        for cookie in self.cookies:
            if cookie.name == name:
                return cookie.value
        return None

    def sign_in(self, user, password):
        """Returns True when RStudio accepted the password, False when it refused."""
        status, _, page = self.request("/auth-sign-in")
        if status != 200:
            raise RuntimeError("sign-in page answered with status %s" % status)
        # The page carries a token that must come back with the form. It protects the
        # form against being posted from another web site.
        match = re.search(r'name="rs-csrf-token"\s+value="([^"]+)"', page)
        token = match.group(1) if match else self.cookie("rs-csrf-token")

        # RStudio publishes an RSA public key as "exponent:modulus" in hexadecimal. The
        # browser encrypts "user<line break>password" with it, so the password does not
        # travel as plain text.
        status, _, key_text = self.request("/auth-public-key")
        if status != 200 or ":" not in key_text:
            raise RuntimeError("no public key from the server (status %s)" % status)
        exponent_hex, modulus_hex = key_text.strip().split(":")
        exponent = int(exponent_hex, 16)
        modulus = int(modulus_hex, 16)
        size = (modulus.bit_length() + 7) // 8

        # RSA encryption with the padding scheme "PKCS#1 version 1.5", which RStudio's
        # page uses: 00 02 <random bytes without zero> 00 <message>.
        message = (user + "\n" + password).encode("utf-8")
        if len(message) > size - 11:
            raise RuntimeError("user name and password are too long for the server's key")
        padding = b""
        while len(padding) < size - 3 - len(message):
            byte = os.urandom(1)
            if byte != b"\x00":
                padding += byte
        block = b"\x00\x02" + padding + b"\x00" + message
        encrypted = pow(int.from_bytes(block, "big"), exponent, modulus).to_bytes(size, "big")

        form = {
            "persist": "0",
            "appUri": "",
            "clientPath": "/auth-sign-in",
            "v": base64.b64encode(encrypted).decode("ascii"),
        }
        if token:
            form["rs-csrf-token"] = token
        status, headers, _ = self.request(
            "/auth-do-sign-in",
            data=urllib.parse.urlencode(form).encode("ascii"),
            headers={"Content-Type": "application/x-www-form-urlencoded"},
        )
        target = headers.get("Location", "") or ""
        # Accepted: RStudio sends the browser to the start page and sets the cookie
        # "user-id". Refused: it sends the browser back to the sign-in page with
        # "error=1" in the address.
        if status == 302 and "error=" not in target and self.cookie("user-id"):
            return True
        if status == 302 and "error=" in target:
            return False
        raise RuntimeError("unexpected answer to the sign-in form: status %s, target %r" % (status, target))

    def rpc(self, group, method, params):
        """One call to the RStudio session, as the RStudio page makes them."""
        token = self.cookie("rs-csrf-token") or ""
        body = {"method": method, "params": params, "clientId": self.client_id or "", "clientVersion": ""}
        status, _, text = self.request(
            "/%s/%s" % (group, method),
            data=json.dumps(body).encode("utf-8"),
            headers={
                "Content-Type": "application/json",
                "Accept": "application/json",
                "X-RS-CSRF-Token": token,
                "X-Requested-With": "XMLHttpRequest",
            },
        )
        try:
            return status, json.loads(text)
        except ValueError:
            return status, {"raw": text[:300]}

    def start_session(self, wait_seconds=90):
        """Starts the R session (RStudio starts it at the first call) and waits for the
        R prompt. Input sent before the first prompt would be lost."""
        deadline = time.time() + wait_seconds
        while time.time() < deadline:
            status, answer = self.rpc("rpc", "client_init", [])
            if status == 200 and isinstance(answer.get("result"), dict):
                self.client_id = answer["result"].get("clientId")
                break
            time.sleep(1)
        if not self.client_id:
            raise RuntimeError("the R session did not start within %s seconds" % wait_seconds)
        if not self.wait_for_prompt(deadline - time.time()):
            raise RuntimeError("the R session showed no prompt")

    def wait_for_prompt(self, wait_seconds):
        """Reads the session's events until the R prompt appears."""
        deadline = time.time() + max(wait_seconds, 1)
        last_event = getattr(self, "last_event", -1)
        while time.time() < deadline:
            status, answer = self.rpc("events", "get_events", [last_event])
            events = answer.get("result") if isinstance(answer, dict) else None
            for event in events or []:
                last_event = event.get("id", last_event)
                if event.get("type") == "console_prompt":
                    self.last_event = last_event
                    return True
            self.last_event = last_event
            time.sleep(0.5)
        return False

    def run_file(self, r_file, wait_seconds=180):
        """Lets the session run source("r_file") and waits for the next prompt."""
        command = 'source(%s, echo = FALSE)' % json.dumps(r_file)
        status, answer = self.rpc("rpc", "console_input", [command, "", 0])
        if status != 200 or "error" in answer:
            raise RuntimeError("the session refused the command: status %s, %r" % (status, answer))
        if not self.wait_for_prompt(wait_seconds):
            raise RuntimeError("the command did not finish within %s seconds" % wait_seconds)


def main():
    if len(sys.argv) < 4 or sys.argv[1] not in ("signin", "run"):
        print(__doc__)
        return 2
    action, url, user = sys.argv[1], sys.argv[2], sys.argv[3]
    password = sys.stdin.readline().rstrip("\n")
    client = Client(url)
    try:
        accepted = client.sign_in(user, password)
        if not accepted:
            print("REFUSED")
            return 1
        print("ACCEPTED")
        if action == "run":
            if len(sys.argv) < 5:
                print("run needs the path of an R file")
                return 2
            client.start_session()
            client.run_file(sys.argv[4])
            print("SESSION-RAN-FILE")
        return 0
    except Exception as error:  # every problem ends as exit code 2 with its reason
        print("CLIENT-ERROR: %s" % error)
        return 2


if __name__ == "__main__":
    sys.exit(main())
