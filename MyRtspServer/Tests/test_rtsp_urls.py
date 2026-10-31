"""Run with: python3 -m unittest discover -s Tests -v (macOS with Xcode)."""

import pathlib
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]

# Supply an encoded access unit without requiring camera hardware.
HARNESS = r'''
import Foundation
import CoreMedia
import Dispatch

struct H264Frame {
    let nalUnits: [Data]
    let presentationTime: CMTime
    let isKeyframe: Bool
    let sps: Data?
    let pps: Data?
}
enum StreamError: Error { case message(String) }
let server = RTSPServer(port: UInt16(CommandLine.arguments[1])!)
try server.start()
server.offer(H264Frame(nalUnits: [Data([0x65, 0x80])], presentationTime: .zero,
                       isKeyframe: true, sps: Data([0x67, 0x4d, 0, 0x1f]),
                       pps: Data([0x68, 0xee])))
dispatchMain()
'''


class RTSPURLTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.directory = tempfile.TemporaryDirectory()
        cls.addClassCleanup(cls.directory.cleanup)
        main = pathlib.Path(cls.directory.name) / "main.swift"
        main.write_text(HARNESS)
        binary = pathlib.Path(cls.directory.name) / "server"
        subprocess.run([
            "xcrun", "swiftc", str(main),
            str(ROOT / "MyRtspServer/RTSPServer.swift"),
            str(ROOT / "MyRtspServer/H264RTPPacketizer.swift"),
            "-o", str(binary),
        ], check=True)
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", 0))
            cls.port = probe.getsockname()[1]
        cls.server = subprocess.Popen([str(binary), str(cls.port)])
        cls.addClassCleanup(cls.stop_server)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if cls.server.poll() is not None:
                raise RuntimeError("RTSP test server exited")
            try:
                with socket.create_connection(("127.0.0.1", cls.port), timeout=0.2):
                    break
            except OSError:
                time.sleep(0.05)
        else:
            raise RuntimeError("RTSP test server did not start")

    @classmethod
    def stop_server(cls):
        cls.server.terminate()
        cls.server.wait(timeout=5)

    def setUp(self):
        self.connection = socket.create_connection(("127.0.0.1", self.port), timeout=2)
        self.addCleanup(self.connection.close)
        self.reader = self.connection.makefile("rb")
        self.addCleanup(self.reader.close)
        self.cseq = 0

    def request(self, method, uri, headers=None):
        self.cseq += 1
        lines = [f"{method} {uri} RTSP/1.0", f"CSeq: {self.cseq}"]
        lines.extend(f"{key}: {value}" for key, value in (headers or {}).items())
        self.connection.sendall(("\r\n".join(lines) + "\r\n\r\n").encode())
        status = self.reader.readline().decode().strip()
        response_headers = {}
        while line := self.reader.readline().decode().strip():
            key, value = line.split(":", 1)
            response_headers[key.lower()] = value.strip()
        body = self.reader.read(int(response_headers.get("content-length", "0")))
        self.assertEqual(response_headers.get("cseq"), str(self.cseq))
        return int(status.split()[1]), response_headers, body

    def test_advertised_urls_support_play_and_teardown(self):
        uri = f"rtsp://127.0.0.1:{self.port}/camera"
        status, headers, body = self.request("DESCRIBE", uri)
        self.assertEqual(status, 200)
        base = headers["content-base"]
        self.assertEqual(base, uri + "/")
        self.assertIn(b"a=control:trackID=0\r\n", body)
        status, headers, _ = self.request("SETUP", base + "trackID=0", {
            "Transport": "RTP/AVP/TCP;unicast;interleaved=0-1"
        })
        self.assertEqual(status, 200)
        session = {"Session": headers["session"]}
        self.assertEqual(self.request("PLAY", base, session)[0], 200)
        self.assertEqual(self.request("PAUSE", uri, session)[0], 200)
        self.assertEqual(self.request("PLAY", uri, session)[0], 200)
        self.assertEqual(self.request("TEARDOWN", base, session)[0], 200)

    def test_unknown_url_is_not_found(self):
        uri = f"rtsp://127.0.0.1:{self.port}/camera/other"
        self.assertEqual(self.request("OPTIONS", uri)[0], 404)


if __name__ == "__main__":
    unittest.main()
