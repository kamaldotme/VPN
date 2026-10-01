"""Thin wrapper around `webauthn` for PrivacyPi.

We support 2nd-factor (in addition to TOTP). The relying-party id is the
hostname the user accesses the dashboard from. Because the same Pi is
reachable as both `privacypi.local` and `192.168.1.155`, registrations
are tied to whichever name was used at register-time. Re-register on the
other name if you need both.
"""
from __future__ import annotations
import base64, json, os
from datetime import datetime
from typing import Any

from webauthn import (
    generate_registration_options, verify_registration_response,
    generate_authentication_options, verify_authentication_response,
    options_to_json,
)
from webauthn.helpers.structs import (
    AuthenticatorSelectionCriteria, UserVerificationRequirement,
    PublicKeyCredentialDescriptor,
)


def b64url_to_bytes(s: str) -> bytes:
    padding = "=" * (-len(s) % 4)
    return base64.urlsafe_b64decode(s + padding)


def bytes_to_b64url(b: bytes) -> str:
    return base64.urlsafe_b64encode(b).decode().rstrip("=")


def rp_id_from_request(request) -> str:
    """Use the host from the Forwarded headers (set by Caddy via ProxyFix).

    WebAuthn requires the RP ID to be the registrable domain of the URL
    the user is actually visiting. Strip the port, ignore IP-literals
    (those work but registrations don't migrate to mDNS hostnames).
    """
    host = request.host.split(":")[0]
    return host


def _user_handle(user_id: int) -> bytes:
    return user_id.to_bytes(8, "big")


def begin_register(user, request, existing_credentials):
    rp_id = rp_id_from_request(request)
    opts = generate_registration_options(
        rp_id=rp_id,
        rp_name="PrivacyPi",
        user_id=_user_handle(user.id),
        user_name=user.username,
        user_display_name=user.username,
        authenticator_selection=AuthenticatorSelectionCriteria(
            user_verification=UserVerificationRequirement.PREFERRED,
        ),
        exclude_credentials=[
            PublicKeyCredentialDescriptor(id=b64url_to_bytes(c.credential_id))
            for c in existing_credentials
        ],
    )
    return json.loads(options_to_json(opts)), bytes_to_b64url(opts.challenge)


def finish_register(user, request, raw_response: dict, expected_challenge: str, label: str):
    rp_id = rp_id_from_request(request)
    origin = request.host_url.rstrip("/")
    verification = verify_registration_response(
        credential=raw_response,
        expected_challenge=b64url_to_bytes(expected_challenge),
        expected_origin=origin,
        expected_rp_id=rp_id,
    )
    return {
        "credential_id": bytes_to_b64url(verification.credential_id),
        "public_key": bytes_to_b64url(verification.credential_public_key),
        "sign_count": verification.sign_count,
        "label": label or "hardware key",
    }


def begin_login(request, credentials):
    rp_id = rp_id_from_request(request)
    opts = generate_authentication_options(
        rp_id=rp_id,
        allow_credentials=[
            PublicKeyCredentialDescriptor(id=b64url_to_bytes(c.credential_id))
            for c in credentials
        ],
        user_verification=UserVerificationRequirement.PREFERRED,
    )
    return json.loads(options_to_json(opts)), bytes_to_b64url(opts.challenge)


def finish_login(request, raw_response: dict, expected_challenge: str, credential):
    rp_id = rp_id_from_request(request)
    origin = request.host_url.rstrip("/")
    verification = verify_authentication_response(
        credential=raw_response,
        expected_challenge=b64url_to_bytes(expected_challenge),
        expected_origin=origin,
        expected_rp_id=rp_id,
        credential_public_key=b64url_to_bytes(credential.public_key),
        credential_current_sign_count=credential.sign_count,
    )
    return verification.new_sign_count
