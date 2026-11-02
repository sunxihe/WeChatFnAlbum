"""Independent signing reference for synthetic protocol tests (GPL-3.0).
Protocol constants are public client identifiers, not user credentials.
"""
import hashlib
import secrets
import time
from urllib.parse import parse_qsl,urlsplit

def photo_authx(url: str, *, nonce: str | None = None,
                timestamp: str | None = None) -> str:
    """Match the APK's SignerInterceptor GET canonicalization.

    The fixed client identifier is in libsskit-native.so; the photo signing
    key is set by C5346n41.d(). These are protocol constants, not user secrets.
    Signing the prepared URL keeps pagination and media query strings intact.
    """
    parsed = urlsplit(url)
    values = {}
    for key, value in parse_qsl(parsed.query, keep_blank_values=True):
        values.setdefault(key, value)  # OkHttp queryParameter() uses first value.
    payload = '&'.join(f'{key}={values[key]}' for key in sorted(values))
    payload_hash = hashlib.md5(payload.encode('utf-8')).hexdigest()
    nonce = nonce or str(100000 + secrets.randbelow(900000))
    timestamp = timestamp or str(time.time_ns() // 1_000_000)
    material = '_'.join(('NDzZTVxnRKP8Z0jXg1VAMonaG8akvh', parsed.path or '/',
                         nonce, timestamp, payload_hash,
                         'EAECCF25-80A6-4666-A7C2-A76904A74AB6'))
    signature = hashlib.md5(material.encode('utf-8')).hexdigest()
    return f'nonce={nonce}&timestamp={timestamp}&sign={signature}'
