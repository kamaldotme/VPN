#!/usr/bin/env bash
set -uo pipefail
BASE_URL="https://$(cat ~/.privacypi-host)"
: "${PRIVACYPI_ADMIN_PASS:?export PRIVACYPI_ADMIN_PASS (admin UI password)}"
: "${PRIVACYPI_TOTP_SECRET:?export PRIVACYPI_TOTP_SECRET (admin TOTP base32 secret)}"

python3 -c "
import urllib3; urllib3.disable_warnings()
import requests, re, pyotp, sys
s = requests.Session(); s.verify = False
BASE = '$BASE_URL'
HDR = {'Referer': f'{BASE}/'}
csrf = re.search(r'csrf_token\" value=\"([^\"]+)\"', s.get(f'{BASE}/login').text).group(1)
s.post(f'{BASE}/login', data={'csrf_token':csrf,'username':'admin','password':'$PRIVACYPI_ADMIN_PASS'}, headers=HDR, allow_redirects=False)
csrf = re.search(r'csrf_token\" value=\"([^\"]+)\"', s.get(f'{BASE}/2fa').text).group(1)
totp = pyotp.TOTP('$PRIVACYPI_TOTP_SECRET').now()
s.post(f'{BASE}/2fa', data={'csrf_token':csrf,'code':totp}, headers=HDR, allow_redirects=False)
csrf2 = re.search(r'csrf-token\" content=\"([^\"]+)\"', s.get(f'{BASE}/').text).group(1)

passes=0; fails=0
def check(d, c):
    global passes, fails
    print(f'  {\"✓\" if c else \"✗\"} {d}')
    passes += int(c); fails += int(not c)

print()
print('[ Backup ]')
r = s.get(f'{BASE}/backup')
check('Backup page renders', r.status_code == 200 and 'encrypted backup' in r.text.lower())
r = s.post(f'{BASE}/api/backup/download', data={'password':'$PRIVACYPI_ADMIN_PASS'}, headers={'X-CSRFToken':csrf2,'Referer':f'{BASE}/backup'})
check('Backup download returns file', r.status_code == 200 and len(r.content) > 1000)
r = s.post(f'{BASE}/api/backup/download', data={'password':'wrong'}, headers={'X-CSRFToken':csrf2,'Referer':f'{BASE}/backup'})
check('Wrong password rejected', r.status_code == 401)

print()
print('[ Leak test ]')
r = s.get(f'{BASE}/api/leak-test')
import json
d = r.json()
check('leak-test returns public_ip', 'public_ip' in d or 'public_ip_err' in d)
check('leak-test returns status JSON', 'status' in d or 'status_err' in d)

print(f'\n==> Result: {passes} passed, {fails} failed')
sys.exit(0 if fails == 0 else 1)
"
