"""提供 Python HTTPS 所需的 CA 证书；保留上游许可证，不关闭证书验证。"""
from __future__ import annotations

import hashlib
import io
from pathlib import Path
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
URL = "https://files.pythonhosted.org/packages/c4/51/29046e48f693c54e5b7412216d447a1d8362c9653148d98c02cdf65fa733/certifi-2026.10.19-py3-none-any.whl"
SHA256 = "42d35340cc5b9ba78e818ddbff0c5b1c2b779de448a340fd1b989f5fa8670e1b"


def prepare():
    request = urllib.request.Request(URL, headers={"User-Agent": "PyPocket-build/1.0"})
    with urllib.request.urlopen(request, timeout=60) as response:
        content = response.read(2 * 1024 * 1024)
    if hashlib.sha256(content).hexdigest() != SHA256:
        raise RuntimeError("Certifi 下载校验失败")
    vendor = ROOT / "Vendor"
    vendor.mkdir(exist_ok=True)
    with zipfile.ZipFile(io.BytesIO(content)) as wheel:
        certificate = wheel.read("certifi/cacert.pem")
        licenses = [name for name in wheel.namelist() if name.endswith("/LICENSE")]
        if len(licenses) != 1:
            raise RuntimeError("Certifi 包中没有唯一的许可证")
        (vendor / "cacert.pem").write_bytes(certificate)
        (vendor / "certifi-LICENSE.txt").write_bytes(wheel.read(licenses[0]))
    print("CA 根证书与 MPL-2.0 许可证已准备。")


if __name__ == "__main__":
    prepare()
