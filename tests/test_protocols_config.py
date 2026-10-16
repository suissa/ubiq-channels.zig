import subprocess
import sys
import tempfile
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts" / "render_protocols.py"


class ProtocolConfigTests(unittest.TestCase):
    def test_committed_caddyfile_matches_yaml(self):
        result = subprocess.run(
            [sys.executable, str(SCRIPT), "--check"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_http2_requires_http1(self):
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory) / "protocols.yml"
            config.write_text(
                "http1: false\nhttp2: true\nhttp3: false\n",
                encoding="utf-8",
            )
            import importlib.util
            spec = importlib.util.spec_from_file_location("render_protocols", SCRIPT)
            renderer = importlib.util.module_from_spec(spec)
            assert spec.loader is not None
            spec.loader.exec_module(renderer)
            with self.assertRaisesRegex(ValueError, "HTTP/1.1 enabled"):
                renderer.parse_config(config)

    def test_grpc_route_is_rendered_from_config(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("render_protocols", SCRIPT)
        renderer = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(renderer)
        values = renderer.DEFAULTS.copy()
        values.update({"http1": "true", "http2": "false", "http3": "false"})
        output = renderer.render(values)
        self.assertIn("protocols h1", output)
        self.assertNotIn("protocols h1 h2", output)
        self.assertNotIn("protocols h1 h2 h3", output)

    def test_grpc_route_is_rendered_from_config(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("render_protocols", SCRIPT)
        renderer = importlib.util.module_from_spec(spec)
        assert spec.loader is not None
        spec.loader.exec_module(renderer)
        values = renderer.DEFAULTS.copy()
        output = renderer.render(values)
        self.assertIn("@grpc path /ubiq.channels.v1.ChannelService/*", output)
        self.assertIn("reverse_proxy h2c://127.0.0.1:9090", output)


if __name__ == "__main__":
    unittest.main()
