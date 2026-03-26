import sys
try:
    import _sqlite3
except ImportError:
    import pysqlite3
    sys.modules["sqlite3"] = pysqlite3
    
import json
import asyncio
import aiosqlite
from aiohttp import web

async def snitch_handler(request):
    try:
        data = await request.json()
        challenge = data.get("challenge")
        status = data.get("status")

        if challenge and status is not None:
            db_path = request.app.get("db_path", "merlin.db")
            async with aiosqlite.connect(db_path) as db:
                async with db.execute("SELECT topic FROM API_Key WHERE key = ?", (challenge,)) as cursor:
                    row = await cursor.fetchone()
                    if row:
                        topic = row[0]
                        payload_str = status if isinstance(status, str) else json.dumps(status)
                        for h in request.app["hooks"]:
                            asyncio.create_task(h.on_message(topic, payload_str))
    except Exception:
        pass
    return web.Response(text="OK", status=200)

async def start_api(hooks, host="0.0.0.0", port=8080, db_path="merlin.db"):
    app = web.Application()
    app["hooks"] = hooks
    app["db_path"] = db_path
    app.router.add_post("/snitch", snitch_handler)
    runner = web.AppRunner(app)
    await runner.setup()
    site = web.TCPSite(runner, host, port)
    await site.start()
    return runner
