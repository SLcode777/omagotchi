#!/usr/bin/env python3
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
QML = ROOT / "PetSprite.qml"
SPRITES = ROOT / "assets" / "sprites"


class PetSpriteFallbackTests(unittest.TestCase):
    def test_unsupported_animations_are_resolved_before_image_load(self):
        source = QML.read_text()
        self.assertIn("function animationExists(form, anim)", source)
        self.assertIn("function resolveAnimation(requested, fallback)", source)
        self.assertIn("resolvedAnim = resolveAnimation(anim, fallbackAnim)", source)
        self.assertNotIn("onStatusChanged: if (status === Image.Error)", source)

    def test_catalog_only_claims_complete_two_frame_animations(self):
        source = QML.read_text()
        catalog_match = re.search(r"readonly property var animationCatalog:\s*\(\{(.*?)\}\)", source, re.S)
        self.assertIsNotNone(catalog_match)
        pairs = set()
        for path in SPRITES.glob("*.png"):
            match = re.fullmatch(r"(.+)_([ab])\.png", path.name)
            if match:
                pairs.add(match.group(1))
        for form, values in re.findall(r'"([^"]+)"\s*:\s*\[([^]]*)\]', catalog_match.group(1)):
            for anim in re.findall(r'"([^"]+)"', values):
                self.assertIn(f"{form}_{anim}", pairs)
                self.assertTrue((SPRITES / f"{form}_{anim}_a.png").is_file())
                self.assertTrue((SPRITES / f"{form}_{anim}_b.png").is_file())


if __name__ == "__main__":
    unittest.main()
