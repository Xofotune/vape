# ─── Vape Bot Configuration ───────────────────────────────────────────────────

BOT_TOKEN = ""

OWNER_ID = 1

# Static authorized user IDs — runtime whitelist managed via $vape whitelist add/remove
AUTHORIZED_USER_IDS = [
    # 111111111111111111,
    # 222222222222222222,
]

# ─── Attack Defaults ──────────────────────────────────────────────────────────

CONNECTIONS = 50000      # concurrent connections per node
DURATION    = 60         # attack duration in seconds
THREADS     = 0          # CPU threads per node  (0 = all cores / auto)
LOWNET      = False      # True = minimum bandwidth mode (~7x less TX)

# ─── Cooldown ─────────────────────────────────────────────────────────────────
# Total cooldown = DURATION + COOLDOWN_EXTRA seconds between attacks.

COOLDOWN_EXTRA = 5

# ─── Embed ────────────────────────────────────────────────────────────────────

EMBED_COLOR  = 0xFFFFFF
EMBED_FOOTER = "Developer: @Paxjest  •  Engine: @Xstairs"
