#!/bin/bash

echo "===================================================="
echo "🚀 欢迎使用 TG-PikPak 多线程双向满血节点一键安装脚本"
echo "===================================================="
echo "⚠️  在开始之前，请确保您已在 my.telegram.org 申请了 API 凭证"
echo ""

# 1. 交互式获取用户的 API_ID 和 API_HASH
read -p "👉 请输入您的 API_ID (纯数字): " USER_API_ID
read -p "👉 请输入您的 API_HASH (字符串): " USER_API_HASH

# 检查输入是否为空
if [ -z "$USER_API_ID" ] || [ -z "$USER_API_HASH" ]; then
    echo "❌ 错误: API_ID 和 API_HASH 不能为空！部署已终止。"
    exit 1
fi

echo ""
echo "✅ 凭证获取成功！正在为您构建服务器环境..."

# 2. 物理扩容：强制给 VPS 增加 2GB 虚拟内存 (防止 1G 小鸡编译 Docker 时崩溃)
echo "⚙️ 检查并配置虚拟内存 (Swap)..."
if [ ! -f /swapfile ]; then
    dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile
    mkswap /swapfile > /dev/null 2>&1
    swapon /swapfile
    echo "✅ 2GB 虚拟内存开启成功！"
else
    echo "✅ 虚拟内存已存在，跳过创建。"
fi

# 3. 创建项目目录
mkdir -p ~/tg_pikpak_docker/data
cd ~/tg_pikpak_docker

# 4. 创建 Docker 免检名单，防止打包时被历史大视频撑爆
echo "data/" > .dockerignore

# 5. 生成核心 Python 机器人代码 (带配置占位符)
echo "🐍 正在生成双向多线程机器人核心代码..."
cat << 'EOF' > bot.py
from telethon import TelegramClient, events
from telethon.tl.functions.upload import SaveBigFilePartRequest
from telethon.tl.types import InputFileBig
import os
import time
import asyncio
import math
import random

# 【由安装脚本自动注入的 API 凭证】
API_ID = REPLACE_ME_API_ID
API_HASH = 'REPLACE_ME_API_HASH'
SESSION_PATH = '/app/data/bot_session'

client = TelegramClient(SESSION_PATH, API_ID, API_HASH)

# ==========================================
# 🚀 引擎 1：迅雷式多线程分块【下载】引擎
# ==========================================
async def fast_multithread_download(client, msg, file_path, progress_cb):
    file_size = msg.file.size
    chunk_size = 2 * 1024 * 1024 
    total_chunks = (file_size + chunk_size - 1) // chunk_size
    downloaded = 0
    last_time = time.time()
    
    with open(file_path, 'wb') as f:
        f.truncate(file_size)
        
    sem = asyncio.Semaphore(5)
    
    async def download_worker(idx):
        nonlocal downloaded, last_time
        offset = idx * chunk_size
        target_limit = chunk_size if (idx < total_chunks - 1) else (file_size - offset)
        
        async with sem:
            stream_bytes = bytearray()
            async for chunk in client.iter_download(msg.media, offset=offset, request_size=512*1024):
                stream_bytes.extend(chunk)
                if len(stream_bytes) >= target_limit:
                    stream_bytes = stream_bytes[:target_limit]
                    break
            
            with open(file_path, 'r+b') as f:
                f.seek(offset)
                f.write(stream_bytes)
                
            downloaded += len(stream_bytes)
            now = time.time()
            if now - last_time > 2:
                last_time = now
                try: await progress_cb(downloaded, file_size, "下载")
                except: pass

    tasks = [download_worker(i) for i in range(total_chunks)]
    await asyncio.gather(*tasks)
    
    try: await progress_cb(file_size, file_size, "下载")
    except: pass
    return file_path

# ==========================================
# 🚀 引擎 2：暴力多线程分块【上传】引擎
# ==========================================
async def fast_multithread_upload(client, file_path, progress_cb):
    file_name = os.path.basename(file_path)
    file_size = os.path.getsize(file_path)
    
    if file_size < 10 * 1024 * 1024:
        return file_path
        
    chunk_size = 512 * 1024 
    total_parts = math.ceil(file_size / chunk_size)
    file_id = random.randint(-9223372036854775808, 9223372036854775807)
    
    uploaded_bytes = 0
    last_time = time.time()
    sem = asyncio.Semaphore(5)
    
    async def upload_worker(part_idx):
        nonlocal uploaded_bytes, last_time
        async with sem:
            with open(file_path, 'rb') as f:
                f.seek(part_idx * chunk_size)
                chunk_data = f.read(chunk_size)
            
            await client(SaveBigFilePartRequest(
                file_id=file_id,
                file_part=part_idx,
                file_total_parts=total_parts,
                bytes=chunk_data
            ))
            
            uploaded_bytes += len(chunk_data)
            now = time.time()
            if now - last_time > 2:
                last_time = now
                try: await progress_cb(uploaded_bytes, file_size, "上传")
                except: pass

    tasks = [upload_worker(i) for i in range(total_parts)]
    await asyncio.gather(*tasks)
    
    try: await progress_cb(file_size, file_size, "上传")
    except: pass
    return InputFileBig(id=file_id, parts=total_parts, name=file_name)

# ==========================================
# 主流程监听：支持单视频与相册合集智能抓取
# ==========================================
@client.on(events.NewMessage(pattern=r'(?i)https://t\.me/(c/|)[a-zA-Z0-9_]+/[0-9]+'))
async def handle_link(event):
    if event.is_private and event.chat_id == (await client.get_me()).id:
        raw_link = event.text.strip().rstrip('/')
        msg = await event.respond("⏳ 正在解析链接...")
        
        try:
            comment_id = None
            if '?comment=' in raw_link:
                comment_id = int(raw_link.split('?comment=')[1].split('&')[0])
                
            link = raw_link.split('?')[0] 
            parts = link.split('/')
            msg_id = int(parts[-1])
            
            if 'c' in parts:
                idx = parts.index('c')
                chat_id = int('-100' + parts[idx+1])
            else:
                tme_idx = parts.index('t.me')
                chat_id = parts[tme_idx+1]
            
            if comment_id:
                msgs = await client.get_messages(chat_id, reply_to=msg_id, limit=1, offset_id=comment_id-1)
                target_msg = msgs[0] if msgs else None
            else:
                target_msg = await client.get_messages(chat_id, ids=msg_id)

            if not target_msg or not getattr(target_msg, 'media', None):
                await msg.edit("❌ 无法获取视频，请检查权限。")
                return

            album_msgs = []
            if target_msg.grouped_id:
                await msg.edit("🔍 探雷成功！这是一个视频合集(相册)，正在把兄弟姐妹全拽出来...")
                history = await client.get_messages(chat_id, limit=20, offset_id=target_msg.id + 10)
                album_msgs = [m for m in history if m.grouped_id == target_msg.grouped_id and getattr(m, 'media', None)]
                album_msgs.sort(key=lambda x: x.id) 
            else:
                album_msgs = [target_msg] 

            total_videos = len(album_msgs)
            if total_videos > 1:
                await msg.edit(f"📦 共锁定 {total_videos} 个相关视频！准备开始批量多线程处理...")

            for current_idx, current_msg in enumerate(album_msgs, 1):
                video_path = None
                file_name = f"video_{current_msg.id}.mp4"
                video_path = os.path.join('/app/data/', file_name)
                
                async def progress_callback(current, total, action_name):
                    percent = (current / total) * 100
                    mb_current = current / (1024 * 1024)
                    mb_total = total / (1024 * 1024)
                    bar_length = 15
                    filled = int(bar_length * current / total)
                    bar = '█' * filled + '░' * (bar_length - filled)
                    icon = "🔥" if action_name == "下载" else "🚀"
                    
                    header = f"📦 **处理进度: 视频 {current_idx} / {total_videos}**\n" if total_videos > 1 else ""
                    
                    try:
                        await msg.edit(f"{header}{icon} **5 线程火力全开{action_name}中...**\n\n"
                                       f"[{bar}] {percent:.1f}%\n"
                                       f"📊 进度: {mb_current:.1f} MB / {mb_total:.1f} MB")
                    except: pass
                
                try:
                    await fast_multithread_download(client, current_msg, video_path, progress_callback)
                    
                    if os.path.exists(video_path):
                        upload_file_handle = await fast_multithread_upload(client, video_path, progress_callback)
                        caption_text = f"合集视频 {current_idx}/{total_videos} : 专属多线程满血转存" if total_videos > 1 else "专属多线程满血转存"
                        await client.send_file('PikPak_Bot', upload_file_handle, caption=caption_text)
                        os.remove(video_path)
                    else:
                        await msg.reply(f"❌ 视频 {current_idx}/{total_videos} 下载失败。")
                except Exception as inner_e:
                    if video_path and os.path.exists(video_path):
                        os.remove(video_path)
                    await msg.reply(f"❌ 视频 {current_idx}/{total_videos} 处理报错: {str(inner_e)}")
                    continue 

            if total_videos > 1:
                await msg.edit(f"🎉 狂欢结束！整个合集的 {total_videos} 个视频全部转存啦！")
            else:
                await msg.edit("🎉 任务圆满完成！PikPak 已光速接收。")
                
        except Exception as e:
            await msg.edit(f"❌ 解析链接总控报错: {str(e)}")

with client:
    print("\n✅ 双向多线程引擎已启动...")
    client.run_until_disconnected()
EOF

# 6. 利用 sed 替换占位符为用户输入的真实凭证
sed -i "s/REPLACE_ME_API_ID/$USER_API_ID/g" bot.py
sed -i "s/REPLACE_ME_API_HASH/$USER_API_HASH/g" bot.py

# 7. 写入 Dockerfile 和 docker-compose.yml
echo "🐳 正在生成 Docker 配置文件..."
cat << 'EOF' > Dockerfile
FROM python:3.9-slim
WORKDIR /app
RUN apt-get update && apt-get install -y gcc libffi-dev libssl-dev && rm -rf /var/lib/apt/lists/*
RUN pip install --no-cache-dir telethon cryptg
COPY bot.py /app/
CMD ["python", "-u", "bot.py"]
EOF

cat << 'EOF' > docker-compose.yml
version: '3.8'
services:
  tg-pikpak-bot:
    build: .
    container_name: tg_pikpak_bot
    restart: unless-stopped
    volumes:
      - ./data:/app/data
EOF

# 8. 编译并启动容器
echo "===================================================="
echo "🚀 配置文件就绪！正在构建并启动容器 (约需 1-2 分钟)..."
docker-compose up -d --build

# 9. 清理并反馈结果
echo "===================================================="
echo "🎉 部署完成！您的专属机器人已在后台稳定运行。"
echo "💡 提示: 初次运行时可能需要在 Telegram 输入验证码进行设备登录验证。"
echo "===================================================="
