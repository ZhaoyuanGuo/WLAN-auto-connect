#!/usr/bin/env python
# 本地预览 website/ 官网，用来肉眼核对改版效果（DESIGN.md §8 的人工验收清单）。
# 只服务仓库里的静态文件，不改动任何东西。
#
#   python tool/serve_website.py            # 只监听 127.0.0.1
#   python tool/serve_website.py --lan      # 监听 0.0.0.0，手机同网段可访问
#   python tool/serve_website.py --port 9000
#
# 两点注意：
# 1. /ga_beian.png 与 /dl/ 只存在于服务器根，仓库里没有。这里把 /ga_beian.png
#    映射到 favicon.svg，免得页脚出现破图让人误判（PRODUCT.md 硬约束）。
# 2. --lan 会把预览暴露到所在网段。校园网/公共 WiFi 下别用，看完 Ctrl+C 关掉。
import argparse
import http.server
import os
import socket

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'website')


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=os.path.abspath(ROOT), **kwargs)

    def do_GET(self):
        if self.path.rstrip('/') == '/ga_beian.png':
            self.path = '/favicon.svg'
        return super().do_GET()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--port', type=int, default=8123)
    ap.add_argument('--lan', action='store_true', help='监听 0.0.0.0，允许同网段手机访问')
    a = ap.parse_args()
    addr = '0.0.0.0' if a.lan else '127.0.0.1'

    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        if probe.connect_ex(('127.0.0.1', a.port)) == 0:
            raise SystemExit(f'端口 {a.port} 已被占用，换一个：--port 9000')

    print(f'官网根目录：{os.path.abspath(ROOT)}')
    print(f'本机：  http://127.0.0.1:{a.port}/')
    if a.lan:
        ips = sorted({i[1] for i in socket.gethostbyname_ex(socket.gethostname())[2] if not i[1].startswith('127.')})
        for ip in ips:
            print(f'手机：  http://{ip}:{a.port}/   （当前暴露在同一网段，用完请关闭）')
    print('页面：  /  /help.html  /share.html  /share-code.html    Ctrl+C 停止')
    http.server.ThreadingHTTPServer((addr, a.port), Handler).serve_forever()


if __name__ == '__main__':
    main()
