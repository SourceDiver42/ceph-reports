#!/usr/bin/env python3
"""Send a plain-text email with optional file attachments via SMTP.

Usage:  send_mail.py <subject> <bodyfile> [attachment ...]

Reads connection details from the environment (injected from the smtp secret):
  SMTP_URL   smtp://host:port (STARTTLS) or smtps://host:port (implicit TLS)
  SMTP_USER  SMTP username (optional; no auth if empty)
  SMTP_PASS  SMTP password
  MAIL_FROM  envelope/From address
  MAIL_TO    recipient (comma separated allowed)
"""
import mimetypes
import os
import smtplib
import ssl
import sys
from email.message import EmailMessage
from urllib.parse import urlsplit


def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write("usage: send_mail.py <subject> <bodyfile> [attachment ...]\n")
        return 2

    subject = sys.argv[1]
    bodyfile = sys.argv[2]
    attachments = sys.argv[3:]

    url = os.environ["SMTP_URL"]
    user = os.environ.get("SMTP_USER", "")
    password = os.environ.get("SMTP_PASS", "")
    mail_from = os.environ["MAIL_FROM"]
    mail_to = [a.strip() for a in os.environ["MAIL_TO"].split(",") if a.strip()]

    parts = urlsplit(url)
    scheme = (parts.scheme or "smtp").lower()
    host = parts.hostname or "localhost"
    implicit_tls = scheme == "smtps"
    port = parts.port or (465 if implicit_tls else 587)

    with open(bodyfile, "r", encoding="utf-8") as fh:
        body = fh.read()

    msg = EmailMessage()
    msg["From"] = mail_from
    msg["To"] = ", ".join(mail_to)
    msg["Subject"] = subject
    msg.set_content(body)

    for path in attachments:
        if not path or not os.path.isfile(path):
            continue
        ctype, _ = mimetypes.guess_type(path)
        maintype, subtype = (ctype.split("/", 1) if ctype else ("application", "octet-stream"))
        with open(path, "rb") as fh:
            msg.add_attachment(
                fh.read(),
                maintype=maintype,
                subtype=subtype,
                filename=os.path.basename(path),
            )

    ctx = ssl.create_default_context()
    if implicit_tls:
        with smtplib.SMTP_SSL(host, port, context=ctx, timeout=60) as smtp:
            if user:
                smtp.login(user, password)
            smtp.send_message(msg, from_addr=mail_from, to_addrs=mail_to)
    else:
        with smtplib.SMTP(host, port, timeout=60) as smtp:
            smtp.ehlo()
            smtp.starttls(context=ctx)
            smtp.ehlo()
            if user:
                smtp.login(user, password)
            smtp.send_message(msg, from_addr=mail_from, to_addrs=mail_to)
    return 0


if __name__ == "__main__":
    sys.exit(main())
