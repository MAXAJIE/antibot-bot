"""Exit-IP reputation.

Datacenter ASNs are challenged an order of magnitude more than consumer ones,
and an exit IP in the wrong country for the region is a standing tell: a
Malaysian session on a German VPS gets the wall on the first request.

Refused before a bot is ever bound, so the failure surfaces at preflight
instead of at T0.
"""
from __future__ import annotations

import ipaddress

from curl_cffi import requests as cffi

LOOKUP = "https://ipapi.co/{ip}/json/"

HOSTING_HINTS = (
    "digitalocean", "amazon", "aws", "ovh", "hetzner", "vultr", "linode",
    "contabo", "oracle", "google", "microsoft", "azure", "alibaba", "tencent",
    "leaseweb", "choopa", "scaleway", "upcloud", "hostinger", "m247",
    "datacamp", "packet", "equinix", "colo",
)
MOBILE_HINTS = ("mobile", "cellular", "wireless", "4g", "lte", "maxis", "celcom",
                "digi", "yes", "unifi mobile")

REGION_COUNTRY = {"sg": "SG", "my": "MY", "id": "ID", "th": "TH", "ph": "PH",
                  "vn": "VN", "tw": "TW", "br": "BR", "mx": "MX"}


class IpIntel:
    __slots__ = ("ip", "asn", "org", "country", "kind", "ok")

    def __init__(self, ip: str, asn: str = "", org: str = "",
                 country: str = "") -> None:
        self.ip = ip
        self.asn = asn
        self.org = org
        self.country = country
        self.ok = bool(ip)
        blob = f"{org} {asn}".lower()
        if any(h in blob for h in MOBILE_HINTS):
            self.kind = "mobile"
        elif any(h in blob for h in HOSTING_HINTS):
            self.kind = "hosting"
        else:
            self.kind = "residential"

    @property
    def residential(self) -> bool:
        return self.kind in ("residential", "mobile")

    def reason(self, require_residential: bool, allow: tuple[str, ...],
               region: str) -> str:
        """Empty string means usable."""
        if not self.ip:
            return "no exit ip"
        if require_residential and not self.residential:
            return f"exit is {self.kind} ({self.org or self.asn})"
        want = allow or ((REGION_COUNTRY[region],) if region in REGION_COUNTRY else ())
        if want and self.country and self.country not in want:
            return f"exit country {self.country} not in {want}"
        return ""


def _valid(ip: str) -> bool:
    try:
        ipaddress.ip_address(ip)
        return True
    except ValueError:
        return False


def lookup(ip: str, timeout: int = 8) -> IpIntel:
    if not _valid(ip):
        return IpIntel("")
    try:
        r = cffi.get(LOOKUP.format(ip=ip), impersonate="chrome", timeout=timeout)
        doc = r.json() if r.status_code == 200 else {}
    except Exception:
        doc = {}
    return IpIntel(ip, str(doc.get("asn") or ""), str(doc.get("org") or ""),
                   str(doc.get("country_code") or ""))