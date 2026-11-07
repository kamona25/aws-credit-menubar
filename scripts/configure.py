#!/usr/bin/env python3
"""One-time local setup. No AWS calls, IAM changes, or secret files."""
import argparse
import getpass
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def ask(prompt, default=None):
    suffix = ' [{}]'.format(default) if default is not None else ''
    value = input(prompt + suffix + ': ').strip()
    return value or default or ''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, default=Path('/Applications/AWS 余量.app'))
    parser.add_argument('--keep-credentials', action='store_true',
                        help='update local configuration without touching Keychain')
    args = parser.parse_args()
    if not sys.stdin.isatty():
        raise ValueError('请在交互式终端运行，以便隐藏密钥输入。')
    binary = args.app.expanduser().resolve() / 'Contents/MacOS/AWSCredit'
    if not os.access(binary, os.X_OK):
        raise ValueError('找不到应用，请先安装到 /Applications，或通过 --app 指定位置。')
    support = Path.home() / 'Library/Application Support/AWSUsageMonitor'
    config_path = support / 'config.json'
    if config_path.exists() and ask('已有配置，是否替换？输入 yes 继续', 'no') != 'yes':
        print('已取消；配置与钥匙串均未更改。')
        return
    print('先退出菜单栏应用；本脚本只配置本机，不会创建 AWS 身份或云资源。')
    account = ask('要查询抵扣金的 AWS 账户 ID（12 位数字）')
    if not re.fullmatch(r'\d{12}', account):
        raise ValueError('账户 ID 必须为 12 位数字。')
    region = ask('账单 API 区域', 'us-east-1')
    payer = ask('汇总管理账户下整个组织的抵扣金？y/n', 'n').lower()
    if payer not in ('y', 'n'):
        raise ValueError('请输入 y 或 n。')
    cli = Path(ask('AWS CLI 可执行文件路径', shutil.which('aws') or '/usr/local/bin/aws')).expanduser().resolve()
    if not cli.is_file() or not os.access(cli, os.X_OK):
        raise ValueError('AWS CLI 路径不是可执行文件。')
    config = {'accountID': account, 'region': region, 'cliPath': str(cli), 'payerAccount': payer == 'y'}
    instance = ask('Lightsail 实例名称（直接回车则仅监控抵扣金）')
    if instance:
        traffic_region = ask('Lightsail 实例所在区域，例如 ap-northeast-1')
        if not traffic_region:
            raise ValueError('监控流量时必须指定实例区域。')
        role = ask('跨账户只读角色 ARN（同账户直接回车）')
        traffic = {'instanceName': instance, 'region': traffic_region}
        if role:
            if not re.fullmatch(r'arn:aws(?:-us-gov|-cn)?:iam::\d{12}:role/[A-Za-z0-9_+=,.@/-]+', role):
                raise ValueError('角色 ARN 格式不正确。')
            traffic['roleARN'] = role
        config['traffic'] = traffic

    if not args.keep_credentials:
        access = getpass.getpass('专用只读 Access Key ID（隐藏输入）: ').strip()
        secret = getpass.getpass('Secret Access Key（隐藏输入）: ').strip()
        token = getpass.getpass('Session Token（长期 IAM 密钥直接回车）: ').strip()
        if not access or not secret:
            raise ValueError('密钥不能为空。')
        credentials = {'accessKeyID': access, 'secretAccessKey': secret}
        if token:
            credentials['sessionToken'] = token
        # Pipe directly to the application. Never put secrets in arguments, env or files.
        result = subprocess.run([str(binary), '--install-credentials'],
                                input=json.dumps(credentials).encode('utf-8'),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        if result.returncode:
            raise ValueError('钥匙串写入未完成；没有保存配置。已有密钥不会被覆盖，见 README 的密钥轮换说明。')
    support.mkdir(parents=True, exist_ok=True, mode=0o700)
    support.chmod(0o700)
    fd, temporary = tempfile.mkstemp(prefix='.config-', dir=str(support))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, 'w', encoding='utf-8') as output:
            json.dump(config, output, ensure_ascii=False, indent=2)
            output.write('\n')
        os.replace(temporary, str(config_path))
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    # Old caches may belong to a different account or instance. Do not reuse them.
    for name in ('balance-cache.json', 'traffic-cache.json', 'status.json'):
        (support / name).unlink(missing_ok=True)
    print('首次配置完成。现在可直接打开应用；日常运行不会弹终端窗口。')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, KeyboardInterrupt, EOFError) as error:
        print('配置未完成：{}'.format(error), file=sys.stderr)
        sys.exit(1)

