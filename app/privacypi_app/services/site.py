"""Read /etc/privacypi/site.conf — the single source of host-specific facts."""

SITE_CONF = "/etc/privacypi/site.conf"


def read_site_conf(path: str = SITE_CONF) -> dict:
    site = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                k, _, v = line.partition("=")
                v = v.strip()
                # Quoted values keep everything inside the quotes; bare values
                # end at an inline comment.
                if v[:1] in ("'", '"') and v[:1] in v[1:]:
                    v = v[1:v.index(v[0], 1)]
                else:
                    v = v.split("#", 1)[0].strip()
                site[k.strip()] = v
    except OSError:
        pass
    return site
