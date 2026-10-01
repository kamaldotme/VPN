#!/usr/bin/env bash
set -uo pipefail
BASE_URL="https://$(cat ~/.privacypi-host)"
: "${PRIVACYPI_ADMIN_PASS:?export PRIVACYPI_ADMIN_PASS (admin UI password)}"
: "${PRIVACYPI_TOTP_SECRET:?export PRIVACYPI_TOTP_SECRET (admin TOTP base32 secret)}"

# Use a Python helper for auth-required tests
python3 -c "
import urllib3; urllib3.disable_warnings()
import requests, re, pyotp, sys
s = requests.Session(); s.verify = False
BASE = '$BASE_URL'
HDR = {'Referer': f'{BASE}/'}
csrf = re.search(r'csrf_token\" value=\"([^\"]+)\"', s.get(f'{BASE}/login').text).group(1)
r = s.post(f'{BASE}/login', data={'csrf_token': csrf, 'username': 'admin', 'password': '$PRIVACYPI_ADMIN_PASS'}, headers=HDR, allow_redirects=False)
csrf = re.search(r'csrf_token\" value=\"([^\"]+)\"', s.get(f'{BASE}/2fa').text).group(1)
totp = pyotp.TOTP('$PRIVACYPI_TOTP_SECRET').now()
s.post(f'{BASE}/2fa', data={'csrf_token': csrf, 'code': totp}, headers=HDR, allow_redirects=False)

pass_count = 0; fail_count = 0
def check(desc, cond):
    global pass_count, fail_count
    print(f'  {\"✓\" if cond else \"✗\"} {desc}')
    if cond: pass_count += 1
    else: fail_count += 1

print()
print('[ Pages render with content ]')
for p, expect in [('/', 'Dashboard'),('/modes','Routing Mode'),('/vpn','VPN Providers'),
                  ('/tor','Tor Configuration'),('/dns','DNS Settings'),
                  ('/diagnostics','Diagnostics'),('/system','System'),('/audit','Audit Log')]:
    r = s.get(f'{BASE}{p}')
    check(f'{p:18s} 200 + has \"{expect}\"', r.status_code == 200 and expect in r.text)

print()
print('[ APIs ]')
csrf2 = re.search(r'csrf-token\" content=\"([^\"]+)\"', s.get(f'{BASE}/').text).group(1)
r = s.post(f'{BASE}/api/mode/direct', headers={'X-CSRFToken': csrf2, 'Referer': f'{BASE}/modes'})
check('mode switch /api/mode/direct returns ok', r.json().get('ok'))
r = s.post(f'{BASE}/api/diag/dig', json={'target':'cloudflare.com'},
           headers={'Content-Type':'application/json','X-CSRFToken': csrf2, 'Referer': f'{BASE}/diagnostics'})
check('diagnostics dig returns rc 0', r.json().get('rc') == 0)
r = s.get(f'{BASE}/api/status')
check('status JSON returns mode', 'mode' in r.json())

print()
print(f'==> Result: {pass_count} passed, {fail_count} failed')
sys.exit(0 if fail_count == 0 else 1)
"
