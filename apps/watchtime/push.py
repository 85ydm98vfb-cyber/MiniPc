"""Notificari Web Push (RFC 8291 aes128gcm + VAPID) - fara servicii externe.
Are nevoie de pachetul 'cryptography' (Alpine: doas apk add py3-cryptography)."""
import base64
import hashlib
import hmac
import json
import os
import struct
import time
import urllib.error
import urllib.parse
import urllib.request

try:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    AVAILABLE = True
except ImportError:  # pachetul lipseste -> notificarile sunt dezactivate, restul aplicatiei merge
    AVAILABLE = False


def b64u(b):
    return base64.urlsafe_b64encode(b).rstrip(b"=").decode()


def unb64u(s):
    return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4))


def _hkdf(salt, ikm, info, length):
    prk = hmac.new(salt, ikm, hashlib.sha256).digest()
    return hmac.new(prk, info + b"\x01", hashlib.sha256).digest()[:length]


class Vapid:
    def __init__(self, path):
        self.path = path
        if os.path.exists(path):
            with open(path, "rb") as f:
                self.key = serialization.load_pem_private_key(f.read(), None)
        else:
            self.key = ec.generate_private_key(ec.SECP256R1())
            with open(path, "wb") as f:
                f.write(self.key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                                               serialization.NoEncryption()))
            os.chmod(path, 0o600)
        self.public_raw = self.key.public_key().public_bytes(serialization.Encoding.X962,
                                                             serialization.PublicFormat.UncompressedPoint)
        self.public_b64 = b64u(self.public_raw)

    def auth_header(self, endpoint, sub):
        u = urllib.parse.urlparse(endpoint)
        head = b64u(json.dumps({"typ": "JWT", "alg": "ES256"}).encode())
        body = b64u(json.dumps({"aud": f"{u.scheme}://{u.netloc}", "exp": int(time.time()) + 12 * 3600, "sub": sub}).encode())
        r, s = decode_dss_signature(self.key.sign(f"{head}.{body}".encode(), ec.ECDSA(hashes.SHA256())))
        sig = b64u(r.to_bytes(32, "big") + s.to_bytes(32, "big"))
        return f"vapid t={head}.{body}.{sig}, k={self.public_b64}"


def encrypt(payload, p256dh, auth):
    ua_pub = unb64u(p256dh)
    auth_secret = unb64u(auth)
    eph = ec.generate_private_key(ec.SECP256R1())
    as_pub = eph.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    shared = eph.exchange(ec.ECDH(), ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), ua_pub))
    ikm = _hkdf(auth_secret, shared, b"WebPush: info\x00" + ua_pub + as_pub, 32)
    salt = os.urandom(16)
    cek = _hkdf(salt, ikm, b"Content-Encoding: aes128gcm\x00", 16)
    nonce = _hkdf(salt, ikm, b"Content-Encoding: nonce\x00", 12)
    ct = AESGCM(cek).encrypt(nonce, payload + b"\x02", None)
    return salt + struct.pack(">I", 4096) + bytes([len(as_pub)]) + as_pub + ct


def send(vapid, sub, data, contact="mailto:watchtime@example.com", ttl=86400):
    """Trimite o notificare. Intoarce 'ok', 'gone' (abonament expirat, de sters) sau 'error:<cod>'."""
    body = encrypt(json.dumps(data).encode(), sub["p256dh"], sub["auth"])
    req = urllib.request.Request(sub["endpoint"], data=body, method="POST", headers={
        "Content-Encoding": "aes128gcm", "Content-Type": "application/octet-stream", "TTL": str(ttl),
        "Urgency": "normal", "Authorization": vapid.auth_header(sub["endpoint"], contact)})
    try:
        with urllib.request.urlopen(req, timeout=15):
            return "ok"
    except urllib.error.HTTPError as e:
        return "gone" if e.code in (404, 410) else f"error:{e.code}"
    except OSError as e:
        return f"error:{e}"
