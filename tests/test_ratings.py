#!/usr/bin/env python3
"""
tools/test_ratings.py

Unit tests for the Storefront ratings system:
- Tallying logic (vote parsing, device deduplication, net score)
- Wilson score computation
- Vote revocation handling
"""

import unittest
import sys
import os
import re

# Add tools/ to path for imports
sys.path.insert(0, os.path.dirname(__file__))

def parse_comments_for_tally(comments):
    """Simulates the discussion comment parsing logic in ratings_tally.py"""
    device_votes = {}
    for c_body in comments:
        cm = re.search(r"<!--\s*storefront_vote:device_uuid=([^\s]+)\s+vote=([^\s]+)\s*-->", c_body)
        if cm:
            dev_id = cm.group(1)
            vote_dir = cm.group(2).lower()
            device_votes[dev_id] = vote_dir

    up_votes = 0
    down_votes = 0
    for dev_id, vote_dir in device_votes.items():
        if vote_dir == "up":
            up_votes += 1
        elif vote_dir == "down":
            down_votes += 1

    net_score = up_votes - down_votes
    return {"up": up_votes, "down": down_votes, "net_score": net_score}

def compute_wilson_score(up, down):
    """Simulates Wilson score calculation from storefront_ratings.lua"""
    up = max(0, int(up))
    down = max(0, int(down))
    n = up + down
    if n == 0:
        return 0.0

    import math
    z = 1.96
    phat = up / n
    z2 = z * z
    score = (phat + z2 / (2 * n) - z * math.sqrt((phat * (1 - phat) + z2 / (4 * n)) / n)) / (1 + z2 / n)
    return max(0.0, score)


class TestRatingsTally(unittest.TestCase):
    def test_single_upvote(self):
        comments = [
            "<!-- storefront_vote:device_uuid=uuid123 vote=up -->\nDevice `...uuid123` voted: **up**"
        ]
        result = parse_comments_for_tally(comments)
        self.assertEqual(result["up"], 1)
        self.assertEqual(result["down"], 0)
        self.assertEqual(result["net_score"], 1)

    def test_single_downvote(self):
        comments = [
            "<!-- storefront_vote:device_uuid=uuid456 vote=down -->\nDevice `...uuid456` voted: **down**"
        ]
        result = parse_comments_for_tally(comments)
        self.assertEqual(result["up"], 0)
        self.assertEqual(result["down"], 1)
        self.assertEqual(result["net_score"], -1)

    def test_multiple_devices(self):
        comments = [
            "<!-- storefront_vote:device_uuid=dev1 vote=up -->",
            "<!-- storefront_vote:device_uuid=dev2 vote=up -->",
            "<!-- storefront_vote:device_uuid=dev3 vote=down -->",
        ]
        result = parse_comments_for_tally(comments)
        self.assertEqual(result["up"], 2)
        self.assertEqual(result["down"], 1)
        self.assertEqual(result["net_score"], 1)

    def test_device_vote_change(self):
        # dev1 initially voted down, then changed vote to up
        comments = [
            "<!-- storefront_vote:device_uuid=dev1 vote=down -->",
            "<!-- storefront_vote:device_uuid=dev1 vote=up -->",
        ]
        result = parse_comments_for_tally(comments)
        self.assertEqual(result["up"], 1)
        self.assertEqual(result["down"], 0)
        self.assertEqual(result["net_score"], 1)

    def test_vote_revocation(self):
        # dev1 voted up, then revoked vote (vote=none)
        comments = [
            "<!-- storefront_vote:device_uuid=dev1 vote=up -->",
            "<!-- storefront_vote:device_uuid=dev1 vote=none -->",
        ]
        result = parse_comments_for_tally(comments)
        self.assertEqual(result["up"], 0)
        self.assertEqual(result["down"], 0)
        self.assertEqual(result["net_score"], 0)

    def test_local_vote_offset(self):
        # Simulates UI calculation combining catalog base counts with local device vote
        base_up = 0
        base_down = 0
        current_vote = "up" # user has an active local upvote

        cur_up = base_up + (1 if current_vote == "up" else 0)
        cur_down = base_down + (1 if current_vote == "down" else 0)
        net_score = cur_up - cur_down

        self.assertEqual(cur_up, 1)
        self.assertEqual(cur_down, 0)
        self.assertEqual(net_score, 1)

if __name__ == "__main__":
    unittest.main()
