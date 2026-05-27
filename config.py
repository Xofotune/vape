# ─── Vape Bot Configuration ───────────────────────────────────────────────────

BOT_TOKEN = ""

OWNER_ID = 1

# Up to 8 authorized user IDs allowed to use $vape
AUTHORIZED_USER_IDS = [
    # 111111111111111111,
    # 222222222222222222,
]

# ─── Attack Defaults ──────────────────────────────────────────────────────────

CONNECTIONS = 50000      # concurrent connections per node
DURATION    = 60         # attack duration in seconds
LOWNET      = False      # True = append "lownet" arg to vape command

# ─── Cooldown ─────────────────────────────────────────────────────────────────
# Global cooldown = DURATION + COOLDOWN_EXTRA seconds
# During cooldown every $vape attempt is rejected with busy message.

COOLDOWN_EXTRA = 5

# ─── Embed ────────────────────────────────────────────────────────────────────

EMBED_COLOR  = 0x8B0000   # dark red
EMBED_FOOTER = "Developer: @Paxjest"
