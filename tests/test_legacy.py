#!/usr/bin/env python3

import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def write(path: Path, content: str, mode: int = 0o755) -> None:
    path.write_text(content)
    path.chmod(mode)


def run(cmd, *, env=None, cwd=None):
    result = subprocess.run(cmd, text=True, capture_output=True, env=env, cwd=cwd)
    if result.returncode != 0:
        raise AssertionError(
            f"command failed ({result.returncode}): {' '.join(map(str, cmd))}\n"
            f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
        )
    return result.stdout


def make_common_mocks(tmp: Path) -> dict:
    bin_dir = tmp / "bin"
    bin_dir.mkdir()

    write(
        bin_dir / "ubus",
        """#!/bin/sh
case "$*" in
  *network.interface.lan*) printf '%s\n' '{"l3_device":"br-lan","device":"br-lan"}' ;;
  *network.interface.wan*) printf '%s\n' '{"l3_device":"pppoe-wan","device":"wan"}' ;;
  *) printf '%s\n' '{}' ;;
esac
""",
    )
    write(
        bin_dir / "jsonfilter",
        r"""#!/bin/sh
input=$(cat)
case "$*" in
  *l3_device*) printf '%s' "$input" | sed -n 's/.*"l3_device":"\([^"]*\)".*/\1/p' ;;
  *device*) printf '%s' "$input" | sed -n 's/.*"device":"\([^"]*\)".*/\1/p' ;;
esac
""",
    )
    write(
        bin_dir / "yq",
        """#!/bin/sh
expr=''
for arg in "$@"; do
  case "$arg" in
    *redir-port*) expr=redir ;;
    *tproxy-port*) expr=tproxy ;;
    *.dns.listen*) expr=dns ;;
    *.tun*|*TUN_LISTENER*) expr=tun ;;
  esac
done
case "$expr" in
  redir) echo 7891 ;;
  tproxy) echo 7892 ;;
  dns) echo '[::]:1053' ;;
  tun) echo nikki ;;
  *) echo '{}' ;;
esac
""",
    )

    functions = tmp / "functions-mock.sh"
    write(
        functions,
        r'''#!/bin/sh
config_load() { :; }
config_get() {
    local __var="$1" section="$2" option="$3" default="${4-}" _mock_value
    _mock_value="$default"
    case "$section.$option" in
        mixin.log_level) _mock_value=warning ;;
        mixin.mode) _mock_value=rule ;;
        mixin.match_process) _mock_value=off ;;
        mixin.outbound_interface) _mock_value=wan ;;
        mixin.ipv6) _mock_value=1 ;;
        mixin.allow_lan) _mock_value=1 ;;
        mixin.mixed_port) _mock_value=7890 ;;
        mixin.redir_port) _mock_value=7891 ;;
        mixin.tproxy_port) _mock_value=7892 ;;
        mixin.authentication) _mock_value=1 ;;
        mixin.tun_enabled) _mock_value=1 ;;
        mixin.tun_device) _mock_value=nikki ;;
        mixin.tun_stack) _mock_value=mixed ;;
        mixin.dns_enabled) _mock_value=1 ;;
        mixin.dns_listen) _mock_value="[::]:1053" ;;
        mixin.dns_ipv6) _mock_value=1 ;;
        mixin.dns_mode) _mock_value=fake-ip ;;
        mixin.fake_ip_range) _mock_value=198.18.0.1/16 ;;
        mixin.dns_nameserver) _mock_value=1 ;;
        mixin.sniffer) _mock_value=1 ;;
        mixin.sniffer_sniff) _mock_value=1 ;;
        mixin.selection_cache) _mock_value=1 ;;
        mixin.fake_ip_cache) _mock_value=1 ;;
        mixin.rule) _mock_value=1 ;;
        mixin.rule_provider) _mock_value=1 ;;
        mixin.geoip_format) _mock_value=dat ;;
        mixin.geodata_loader) _mock_value=standard ;;
        mixin.geox_auto_update) _mock_value=1 ;;
        mixin.geox_update_interval) _mock_value=24 ;;
        mixin.api_listen) _mock_value=0.0.0.0:9090 ;;
        routing.core_fw_mark) _mock_value=0x82 ;;
        routing.core_fw_mask) _mock_value=0xFF ;;
        routing.tproxy_fw_mark) _mock_value=0x80 ;;
        routing.tproxy_fw_mask) _mock_value=0xFF ;;
        routing.tun_fw_mark) _mock_value=0x81 ;;
        routing.tun_fw_mask) _mock_value=0xFF ;;
        core.redirect_listener_name) _mock_value=redir-in ;;
        core.tun_listener_name) _mock_value=tun-in ;;
        core.tproxy_listener_name) _mock_value=tproxy-in ;;
        proxy.enabled) _mock_value=1 ;;
        proxy.ipv4_tcp_mode) _mock_value=redirect ;;
        proxy.ipv4_udp_mode) _mock_value=tun ;;
        proxy.ipv6_tcp_mode) _mock_value=tun ;;
        proxy.ipv6_udp_mode) _mock_value=tproxy ;;
        proxy.ipv4_dns_mode) _mock_value=redirect ;;
        proxy.ipv6_dns_mode) _mock_value=redirect ;;
        proxy.tun_timeout) _mock_value=30 ;;
        proxy.tun_interval) _mock_value=1 ;;
        proxy.router_proxy) _mock_value=1 ;;
        proxy.lan_proxy) _mock_value=1 ;;
        proxy.bypass_china_mainland_ip) _mock_value=1 ;;
        proxy.bypass_china_mainland_ip6) _mock_value=1 ;;
        proxy.proxy_tcp_dport) _mock_value='80 443 8000-8010' ;;
        proxy.proxy_udp_dport) _mock_value='53 123 443' ;;
        auth0.enabled) _mock_value=1 ;;
        auth0.username) _mock_value=nikki ;;
        auth0.password) _mock_value=secret ;;
        ns0.enabled) _mock_value=1 ;;
        ns0.type) _mock_value=default-nameserver ;;
        ns1.enabled) _mock_value=1 ;;
        ns1.type) _mock_value=nameserver ;;
        sniff0.enabled) _mock_value=1 ;;
        sniff0.protocol) _mock_value=HTTP ;;
        sniff0.overwrite_destination) _mock_value=1 ;;
        rp0.enabled) _mock_value=1 ;;
        rp0.name) _mock_value=private ;;
        rp0.type) _mock_value=http ;;
        rp0.url) _mock_value=https://example.invalid/private.yaml ;;
        rp0.file_format) _mock_value=yaml ;;
        rp0.behavior) _mock_value=domain ;;
        rp0.update_interval) _mock_value=86400 ;;
        rule0.enabled) _mock_value=1 ;;
        rule0.type) _mock_value=DOMAIN-SUFFIX ;;
        rule0.matcher) _mock_value=example.com ;;
        rule0.node) _mock_value=DIRECT ;;
        rule0.no_resolve) _mock_value=0 ;;
        rac_root.enabled) _mock_value=1 ;;
        rac_root.dns) _mock_value=0 ;;
        rac_root.proxy) _mock_value=0 ;;
        rac_default.enabled) _mock_value=1 ;;
        rac_default.dns) _mock_value=1 ;;
        rac_default.proxy) _mock_value=1 ;;
        lac_ip4.enabled) _mock_value=1 ;;
        lac_ip4.dns) _mock_value=0 ;;
        lac_ip4.proxy) _mock_value=0 ;;
        lac_ip6.enabled) _mock_value=1 ;;
        lac_ip6.dns) _mock_value=1 ;;
        lac_ip6.proxy) _mock_value=1 ;;
        lac_mac.enabled) _mock_value=1 ;;
        lac_mac.dns) _mock_value=0 ;;
        lac_mac.proxy) _mock_value=0 ;;
        lac_default.enabled) _mock_value=1 ;;
        lac_default.dns) _mock_value=1 ;;
        lac_default.proxy) _mock_value=1 ;;
    esac
    eval "$__var=\"\$_mock_value\""
}
config_get_bool() {
    local __var="$1" value
    config_get value "$2" "$3" "${4-0}"
    case "$value" in 1|on|true|yes|enabled) value=1 ;; *) value=0 ;; esac
    eval "$__var=\$value"
}
config_list_foreach() {
    local section="$1" option="$2" callback="$3"; shift 3
    local values=''
    case "$section.$option" in
        proxy.lan_inbound_interface) values='lan' ;;
        proxy.reserved_ip) values='0.0.0.0/8 10.0.0.0/8 127.0.0.0/8 192.168.0.0/16' ;;
        proxy.reserved_ip6) values='::/128 ::1/128 fc00::/7 fe80::/10 ff00::/8' ;;
        proxy.bypass_dscp) values='4' ;;
        proxy.bypass_fwmark) values='0x99/0xFF' ;;
        auth0.*) values='' ;;
        ns0.nameserver) values='223.5.5.5 223.6.6.6' ;;
        ns1.nameserver) values='https://1.1.1.1/dns-query' ;;
        sniff0.port) values='80 8080' ;;
        rac_root.user) values='root' ;;
        rac_root.group) values='root' ;;
        rac_default.*) values='' ;;
        lac_ip4.ip) values='192.0.2.10' ;;
        lac_ip6.ip6) values='2001:db8::10' ;;
        lac_mac.mac) values='AA:BB:CC:DD:EE:FF' ;;
        lac_default.*) values='' ;;
    esac
    local value
    for value in $values; do "$callback" "$value" "$@"; done
}
config_foreach() {
    local callback="$1" type="$2"; shift 2
    local extra1="${1-}" extra2="${2-}" sections section
    case "$type" in
        authentication) sections='auth0' ;;
        nameserver) sections='ns0 ns1' ;;
        nameserver_policy|proxy_server_nameserver_policy|hosts) sections='' ;;
        sniff) sections='sniff0' ;;
        rule_provider) sections='rp0' ;;
        rule) sections='rule0' ;;
        router_access_control) sections='rac_root rac_default' ;;
        lan_access_control) sections='lac_ip4 lac_ip6 lac_mac lac_default' ;;
        *) sections='' ;;
    esac
    for section in $sections; do "$callback" "$section" "$extra1" "$extra2"; done
}
''',
    )
    return {"bin": bin_dir, "functions": functions}


def make_jshn_mock(tmp: Path) -> Path:
    helper = tmp / "jshn-helper.py"
    write(
        helper,
        r'''#!/usr/bin/env python3
import json, os
ops_path = os.environ['JSHN_OPS']
root = {}
stack = [root]
for raw in open(ops_path, encoding='utf-8'):
    parts = raw.rstrip('\n').split('\t')
    op = parts[0]
    cur = stack[-1]
    def add(key, value):
        if isinstance(cur, list):
            cur.append(value)
        else:
            cur[key] = value
    if op == 'object':
        value = {}
        add(parts[1], value)
        stack.append(value)
    elif op == 'array':
        value = []
        add(parts[1], value)
        stack.append(value)
    elif op == 'close':
        stack.pop()
    elif op == 'string':
        add(parts[1], parts[2])
    elif op == 'int':
        add(parts[1], int(parts[2], 0))
    elif op == 'bool':
        add(parts[1], bool(int(parts[2])))
print(json.dumps(root, ensure_ascii=False, separators=(',', ':')))
''',
    )
    jshn = tmp / "jshn-mock.sh"
    write(
        jshn,
        f'''#!/bin/sh
json_init() {{ : > "$JSHN_OPS"; }}
json_add_object() {{ printf 'object\\t%s\\n' "$1" >> "$JSHN_OPS"; }}
json_add_array() {{ printf 'array\\t%s\\n' "$1" >> "$JSHN_OPS"; }}
json_close_object() {{ printf 'close\\n' >> "$JSHN_OPS"; }}
json_close_array() {{ printf 'close\\n' >> "$JSHN_OPS"; }}
json_add_string() {{ printf 'string\\t%s\\t%s\\n' "$1" "$2" >> "$JSHN_OPS"; }}
json_add_int() {{ printf 'int\\t%s\\t%s\\n' "$1" "$2" >> "$JSHN_OPS"; }}
json_add_boolean() {{ printf 'bool\\t%s\\t%s\\n' "$1" "$2" >> "$JSHN_OPS"; }}
json_dump() {{ python3 "{helper}"; }}
''',
    )
    return jshn


def transformed_script(src: Path, dst: Path, functions: Path, second_include: Path) -> None:
    text = src.read_text()
    text = text.replace('. /lib/functions.sh', f'. "{functions}"', 1)
    if 'jshn.sh' in text:
        text = text.replace('. /usr/share/libubox/jshn.sh', f'. "{second_include}"', 1)
    else:
        text = text.replace('. /etc/nikki/scripts/include.sh', f'. "{second_include}"', 1)
    write(dst, text)


def test_mixin(tmp: Path, common: dict) -> None:
    jshn = make_jshn_mock(tmp)
    script = tmp / "mixin.sh"
    transformed_script(ROOT / "nikki/files/scripts/mixin.sh", script, common["functions"], jshn)
    env = os.environ.copy()
    env["PATH"] = f"{common['bin']}:{env['PATH']}"
    env["JSHN_OPS"] = str(tmp / "jshn-ops.tsv")
    output = run(["/bin/sh", str(script)], env=env)
    data = json.loads(output)
    assert data["interface-name"] == "pppoe-wan"
    assert data["redir-port"] == 7891
    assert data["tproxy-port"] == 7892
    assert data["routing-mark"] == 0x82
    assert data["dns"]["listen"] == "[::]:1053"
    assert data["ipv6"] is True
    assert data["dns"]["ipv6"] is True
    assert data["authentication"] == ["nikki:secret"]
    assert data["dns"]["default-nameserver"] == ["223.5.5.5", "223.6.6.6"]
    assert data["sniffer"]["sniff"]["HTTP"]["port"] == ["80", "8080"]
    assert data["rule-providers"]["private"]["type"] == "http"
    assert data["nikki-rules"] == ["DOMAIN-SUFFIX,example.com,DIRECT"]



def test_default_mixin_policy(tmp: Path) -> None:
    functions = tmp / "functions-defaults.sh"
    write(
        functions,
        r'''#!/bin/sh
config_load() { :; }
config_get() {
    local __var="$1" section="$2" option="$3" default="${4-}" _mock_value="$default"
    case "$section.$option" in
        mixin.log_level) _mock_value=warning ;;
        mixin.mode) _mock_value=rule ;;
        mixin.match_process) _mock_value=off ;;
        mixin.tun_enabled) _mock_value=1 ;;
        mixin.tun_device) _mock_value=nikki ;;
        mixin.tun_stack) _mock_value=gvisor ;;
        mixin.dns_enabled) _mock_value=1 ;;
        mixin.dns_listen) _mock_value='[::]:1053' ;;
        routing.core_fw_mark) _mock_value=0x82 ;;
    esac
    eval "$__var=\$_mock_value"
}
config_get_bool() {
    local __var="$1" value
    config_get value "$2" "$3" "${4-0}"
    case "$value" in 1|on|true|yes|enabled) value=1 ;; *) value=0 ;; esac
    eval "$__var=\$value"
}
config_list_foreach() { :; }
config_foreach() { :; }
''',
    )
    jshn = make_jshn_mock(tmp)
    script = tmp / "mixin-defaults.sh"
    transformed_script(ROOT / "nikki/files/scripts/mixin.sh", script, functions, jshn)
    env = os.environ.copy()
    env["JSHN_OPS"] = str(tmp / "jshn-default-ops.tsv")
    data = json.loads(run(["/bin/sh", str(script)], env=env))
    assert data["log-level"] == "warning"
    assert data["mode"] == "rule"
    assert data["find-process-mode"] == "off"
    assert data["tun"] == {"enable": True, "device": "nikki", "stack": "gvisor"}
    assert data["dns"]["enable"] is True
    assert data["dns"]["listen"] == "[::]:1053"
    assert "ipv6" not in data
    assert "cache-algorithm" not in data["dns"]
    assert "enhanced-mode" not in data["dns"]
    assert "sniffer" not in data


def test_firewall(tmp: Path, common: dict) -> None:
    runtime = tmp / "runtime"
    runtime.mkdir()
    (runtime / "config.yaml").write_text("test: true\n")
    include = tmp / "include-mock.sh"
    write(
        include,
        f'''#!/bin/sh
TEMP_DIR="{runtime}"
RUN_PROFILE_PATH="{runtime / 'config.yaml'}"
APP_LOG_PATH="{runtime / 'app.log'}"
prepare_files() {{ mkdir -p "$TEMP_DIR"; : > "$APP_LOG_PATH"; }}
log() {{ printf '[%s] %s\\n' "$1" "$2" >> "$APP_LOG_PATH"; }}
''',
    )
    script = tmp / "firewall.sh"
    transformed_script(ROOT / "nikki/files/scripts/firewall_fw3.sh", script, common["functions"], include)
    env = os.environ.copy()
    env["PATH"] = f"{common['bin']}:{env['PATH']}"
    rules = run(["/bin/sh", str(script), "render"], env=env)

    expected = [
        "NIK_NAT_PRE_DNS_V4",
        "NIK_NAT_PRE_TCP_V4",
        "NIK_NAT_OUT_DNS_V4",
        "NIK_NAT_OUT_TCP_V4",
        "NIK_MGL_PRE_CTRL_V4",
        "NIK_MGL_PRE_TPROXY_V4",
        "NIK_MGL_PRE_TUN_V4",
        "NIK_MGL_OUT_MARK_V4",
        "NIK_MGL_OUT_TUN_V4",
        "NIK_FLT_IN_TUN_V4",
        "NIK_FLT_FWD_TUN_V4",
        "NIK_NAT_PRE_DNS_V6",
        "NIK_NAT_PRE_TCP_V6",
        "NIK_NAT_OUT_DNS_V6",
        "NIK_NAT_OUT_TCP_V6",
        "NIK_MGL_PRE_CTRL_V6",
        "NIK_MGL_PRE_TPROXY_V6",
        "NIK_MGL_PRE_TUN_V6",
        "NIK_MGL_OUT_MARK_V6",
        "NIK_MGL_OUT_TUN_V6",
        "NIK_FLT_IN_TUN_V6",
        "NIK_FLT_FWD_TUN_V6",
    ]
    for chain in expected:
        assert chain in rules
        assert len(chain) <= 28
    assert rules.count("-I PREROUTING 1 -j NIK_MGL_PRE_CTRL_V4") == 1
    assert rules.count("-I PREROUTING 1 -j NIK_MGL_PRE_CTRL_V6") == 1
    # iptables -I 1 reverses command order: emitting TCP before DNS leaves DNS first.
    assert rules.index("-I PREROUTING 1 -j NIK_NAT_PRE_TCP_V4") < rules.index("-I PREROUTING 1 -j NIK_NAT_PRE_DNS_V4")
    assert rules.index("-I OUTPUT 1 -j NIK_NAT_OUT_TCP_V4") < rules.index("-I OUTPUT 1 -j NIK_NAT_OUT_DNS_V4")
    ipv6_rules = rules.split("# IPv6 / ip6tables-restore", 1)[1]
    assert "*nat" in ipv6_rules
    assert "NIK_NAT_PRE_DNS_V6" in ipv6_rules
    assert "NIK_NAT_OUT_DNS_V6" in ipv6_rules
    assert "-j TPROXY --on-port 7892 --tproxy-mark 0x80/0xFF" in rules
    assert "NIK_MGL_PRE_TUN_V4" in rules
    assert "NIK_MGL_PRE_TUN_V6" in rules
    assert "--set-xmark 0x81/0xFF" in rules
    assert "-i nikki -j ACCEPT" in rules
    assert "-o nikki -j ACCEPT" in rules
    assert "*filter" in rules
    assert "NIK_MGL_PRE_TPROXY_V6 -p udp -j TPROXY --on-port 7892" in rules
    assert "NIK_MGL_PRE_TPROXY_V6 -p tcp -j TPROXY --on-port 7892" not in rules
    assert re.search(r"NIK_NAT_PRE_DNS_V6 -i br-lan\s+-s 2001:db8::10 -p udp --dport 53 -j REDIRECT --to-ports 1053", rules)
    assert re.search(r"NIK_NAT_PRE_DNS_V6 -i br-lan\s+-s 2001:db8::10 -p tcp --dport 53 -j REDIRECT --to-ports 1053", rules)
    assert "-j REDIRECT --to-ports 7891" in rules
    assert re.search(r"NIK_NAT_PRE_DNS_V4 -i br-lan\s+-p udp --dport 53 -j REDIRECT --to-ports 1053", rules)
    assert re.search(r"NIK_NAT_PRE_DNS_V4 -i br-lan\s+-p tcp --dport 53 -j REDIRECT --to-ports 1053", rules)
    assert "--mac-source AA:BB:CC:DD:EE:FF" in rules
    assert "-s 192.0.2.10" in rules
    assert "-s 2001:db8::10" in rules
    # Family-specific selectors must not become wildcard rules in the other family.
    assert "NIK_NAT_PRE_TCP_V4 -i br-lan -s 2001:db8::10" not in rules
    assert "NIK_MGL_PRE_CTRL_V6 -i br-lan -s 192.0.2.10" not in rules
    assert "--uid-owner root" in rules
    assert "--gid-owner root" in rules
    assert "--set-xmark 0x80/0xFF" in rules
    assert "--dports 80,443,8000:8010" in rules
    assert "--dports 53,123,443" in rules
    assert "# IPv4 / iptables-restore" in rules
    assert "# IPv6 / ip6tables-restore" in rules
    assert "nik_reserved_v6" in rules
    assert "nik_china_v6" in rules
    assert "nft" not in rules.lower()
    assert not re.search(r"--(?:on-port|to-ports)\s*(?:$|\n)", rules)





def test_default_firewall_modes(tmp: Path, common: dict) -> None:
    runtime = tmp / "runtime-default-firewall"
    runtime.mkdir()
    (runtime / "config.yaml").write_text("test: true\n")
    include = tmp / "include-default-firewall.sh"
    write(
        include,
        f'''#!/bin/sh
TEMP_DIR="{runtime}"
RUN_PROFILE_PATH="{runtime / 'config.yaml'}"
APP_LOG_PATH="{runtime / 'app.log'}"
prepare_files() {{ mkdir -p "$TEMP_DIR"; : > "$APP_LOG_PATH"; }}
log() {{ :; }}
''',
    )
    defaults_functions = tmp / "functions-default-firewall.sh"
    text = common["functions"].read_text()
    text = text.replace("proxy.ipv4_tcp_mode) _mock_value=redirect", "proxy.ipv4_tcp_mode) _mock_value=tproxy")
    text = text.replace("proxy.ipv4_udp_mode) _mock_value=tun", "proxy.ipv4_udp_mode) _mock_value=tproxy")
    text = text.replace("proxy.ipv6_tcp_mode) _mock_value=tun", "proxy.ipv6_tcp_mode) _mock_value=redirect")
    write(defaults_functions, text)
    script = tmp / "firewall-defaults.sh"
    transformed_script(ROOT / "nikki/files/scripts/firewall_fw3.sh", script, defaults_functions, include)
    env = os.environ.copy()
    env["PATH"] = f"{common['bin']}:{env['PATH']}"
    rules = run(["/bin/sh", str(script), "render"], env=env)
    ipv4 = rules.split("# IPv6 / ip6tables-restore", 1)[0]
    ipv6 = rules.split("# IPv6 / ip6tables-restore", 1)[1]
    assert "NIK_MGL_PRE_TPROXY_V4 -p tcp -j TPROXY --on-port 7892" in ipv4
    assert "NIK_MGL_PRE_TPROXY_V4 -p udp -j TPROXY --on-port 7892" in ipv4
    assert "NIK_NAT_PRE_TCP_V4 -p tcp -j REDIRECT" not in ipv4
    assert "--dport 53 -j REDIRECT --to-ports 1053" in ipv4
    assert "NIK_MGL_PRE_TPROXY_V6 -p tcp -j TPROXY --on-port 7892" not in ipv6
    assert "NIK_MGL_PRE_TPROXY_V6 -p udp -j TPROXY --on-port 7892" in ipv6
    assert "NIK_NAT_PRE_TCP_V6" in ipv6
    assert "-j REDIRECT --to-ports 7891" in ipv6
    assert "--dport 53 -j REDIRECT --to-ports 1053" in ipv6
    assert "--dport 53 -j MARK --set-xmark 0x80/0xFF" not in ipv6


def test_ipv4_tcp_tproxy(tmp: Path, common: dict) -> None:
    runtime = tmp / "runtime-v4-tcp-tproxy"
    runtime.mkdir()
    (runtime / "config.yaml").write_text("test: true\n")
    include = tmp / "include-v4-tcp-tproxy.sh"
    write(
        include,
        f"""#!/bin/sh
TEMP_DIR="{runtime}"
RUN_PROFILE_PATH="{runtime / 'config.yaml'}"
APP_LOG_PATH="{runtime / 'app.log'}"
prepare_files() {{ mkdir -p "$TEMP_DIR"; : > "$APP_LOG_PATH"; }}
log() {{ :; }}
""",
    )
    functions = tmp / "functions-v4-tcp-tproxy.sh"
    text = common["functions"].read_text()
    text = text.replace("proxy.ipv4_tcp_mode) _mock_value=redirect ;;", "proxy.ipv4_tcp_mode) _mock_value=tproxy ;;")
    text = text.replace("proxy.ipv4_udp_mode) _mock_value=tun ;;", "proxy.ipv4_udp_mode) _mock_value=disable ;;")
    text = text.replace("proxy.ipv6_tcp_mode) _mock_value=tun ;;", "proxy.ipv6_tcp_mode) _mock_value=disable ;;")
    text = text.replace("proxy.ipv6_udp_mode) _mock_value=tproxy ;;", "proxy.ipv6_udp_mode) _mock_value=disable ;;")
    text = text.replace("proxy.ipv4_dns_mode) _mock_value=redirect ;;", "proxy.ipv4_dns_mode) _mock_value=disable ;;")
    text = text.replace("proxy.ipv6_dns_mode) _mock_value=redirect ;;", "proxy.ipv6_dns_mode) _mock_value=disable ;;")
    write(functions, text)
    script = tmp / "firewall-v4-tcp-tproxy.sh"
    transformed_script(ROOT / "nikki/files/scripts/firewall_fw3.sh", script, functions, include)
    env = os.environ.copy()
    env["PATH"] = f"{common['bin']}:{env['PATH']}"
    rules = run(["/bin/sh", str(script), "render"], env=env)
    assert "# IPv4 / iptables-restore" in rules
    assert "# IPv6 / ip6tables-restore" not in rules
    assert "-I PREROUTING 1 -j NIK_NAT_PRE_TCP_V4" not in rules
    assert "-I OUTPUT 1 -j NIK_NAT_OUT_TCP_V4" not in rules
    assert "-A NIK_NAT_PRE_TCP_V4 " not in rules
    assert "-A NIK_NAT_OUT_TCP_V4 " not in rules
    assert "NIK_MGL_PRE_TPROXY_V4 -p tcp -j TPROXY --on-port 7892" in rules
    assert re.search(r"-p tcp(?: .*?)? -j MARK --set-xmark 0x80/0xFF", rules)



def test_ipv6_tcp_redirect(tmp: Path, common: dict) -> None:
    runtime = tmp / "runtime-v6-tcp-redirect"
    runtime.mkdir()
    (runtime / "config.yaml").write_text("test: true\n")
    include = tmp / "include-v6-tcp-redirect.sh"
    write(
        include,
        f"""#!/bin/sh
TEMP_DIR="{runtime}"
RUN_PROFILE_PATH="{runtime / 'config.yaml'}"
APP_LOG_PATH="{runtime / 'app.log'}"
prepare_files() {{ mkdir -p "$TEMP_DIR"; : > "$APP_LOG_PATH"; }}
log() {{ :; }}
""",
    )
    functions = tmp / "functions-v6-tcp-redirect.sh"
    text = common["functions"].read_text()
    text = text.replace("proxy.ipv4_tcp_mode) _mock_value=redirect ;;", "proxy.ipv4_tcp_mode) _mock_value=disable ;;")
    text = text.replace("proxy.ipv4_udp_mode) _mock_value=tun ;;", "proxy.ipv4_udp_mode) _mock_value=disable ;;")
    text = text.replace("proxy.ipv6_tcp_mode) _mock_value=tun ;;", "proxy.ipv6_tcp_mode) _mock_value=redirect ;;")
    text = text.replace("proxy.ipv6_udp_mode) _mock_value=tproxy ;;", "proxy.ipv6_udp_mode) _mock_value=disable ;;")
    text = text.replace("proxy.ipv4_dns_mode) _mock_value=redirect ;;", "proxy.ipv4_dns_mode) _mock_value=disable ;;")
    text = text.replace("proxy.ipv6_dns_mode) _mock_value=redirect ;;", "proxy.ipv6_dns_mode) _mock_value=disable ;;")
    write(functions, text)
    bin_dir = tmp / "bin-v6-tcp-redirect"
    shutil.copytree(common["bin"], bin_dir)
    write(
        bin_dir / "yq",
        """#!/bin/sh
for arg in "$@"; do
  case "$arg" in
    *redir-port*) echo 7891; exit 0 ;;
    *tproxy-port*|*.dns.listen*|*.tun.device*) echo 'unexpected non-REDIRECT listener lookup' >&2; exit 88 ;;
  esac
done
echo '{}'
""",
    )
    script = tmp / "firewall-v6-tcp-redirect.sh"
    transformed_script(ROOT / "nikki/files/scripts/firewall_fw3.sh", script, functions, include)
    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    rules = run(["/bin/sh", str(script), "render"], env=env)
    assert "# IPv4 / iptables-restore" not in rules
    assert "# IPv6 / ip6tables-restore" in rules
    assert "-I PREROUTING 1 -j NIK_NAT_PRE_TCP_V6" in rules
    assert "-I OUTPUT 1 -j NIK_NAT_OUT_TCP_V6" in rules
    assert re.search(r"NIK_NAT_PRE_TCP_V6 -i br-lan.*-p tcp.*-j REDIRECT --to-ports 7891", rules)
    assert re.search(r"NIK_NAT_OUT_TCP_V6 .* -p tcp.*-j REDIRECT --to-ports 7891", rules)
    assert "-j TPROXY" not in rules
    assert "--set-xmark 0x81/0xFF" not in rules
    assert "NIK_NAT_PRE_DNS_V6 -i br-lan" not in rules


def test_ipv4_dns_tproxy(tmp: Path, common: dict) -> None:
    runtime = tmp / "runtime-v4-dns-tproxy"
    runtime.mkdir()
    (runtime / "config.yaml").write_text("test: true\n")
    include = tmp / "include-v4-dns-tproxy.sh"
    write(
        include,
        f"""#!/bin/sh
TEMP_DIR="{runtime}"
RUN_PROFILE_PATH="{runtime / 'config.yaml'}"
APP_LOG_PATH="{runtime / 'app.log'}"
prepare_files() {{ mkdir -p "$TEMP_DIR"; : > "$APP_LOG_PATH"; }}
log() {{ :; }}
""",
    )
    functions = tmp / "functions-v4-dns-tproxy.sh"
    text = common["functions"].read_text()
    for old, new in (
        ("proxy.ipv4_tcp_mode) _mock_value=redirect ;;", "proxy.ipv4_tcp_mode) _mock_value=disable ;;"),
        ("proxy.ipv4_udp_mode) _mock_value=tun ;;", "proxy.ipv4_udp_mode) _mock_value=disable ;;"),
        ("proxy.ipv6_tcp_mode) _mock_value=tun ;;", "proxy.ipv6_tcp_mode) _mock_value=disable ;;"),
        ("proxy.ipv6_udp_mode) _mock_value=tproxy ;;", "proxy.ipv6_udp_mode) _mock_value=disable ;;"),
        ("proxy.ipv4_dns_mode) _mock_value=redirect ;;", "proxy.ipv4_dns_mode) _mock_value=tproxy ;;"),
        ("proxy.ipv6_dns_mode) _mock_value=redirect ;;", "proxy.ipv6_dns_mode) _mock_value=disable ;;"),
    ):
        text = text.replace(old, new)
    write(functions, text)
    bin_dir = tmp / "bin-v4-dns-tproxy"
    shutil.copytree(common["bin"], bin_dir)
    write(
        bin_dir / "yq",
        """#!/bin/sh
for arg in "$@"; do
  case "$arg" in
    *tproxy-port*) echo 7892; exit 0 ;;
    *redir-port*|*.dns.listen*|*.tun.device*) echo 'unexpected non-TPROXY listener lookup' >&2; exit 88 ;;
  esac
done
echo '{}'
""",
    )
    script = tmp / "firewall-v4-dns-tproxy.sh"
    transformed_script(ROOT / "nikki/files/scripts/firewall_fw3.sh", script, functions, include)
    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    rules = run(["/bin/sh", str(script), "render"], env=env)
    assert "# IPv4 / iptables-restore" in rules
    assert "# IPv6 / ip6tables-restore" not in rules
    assert "REDIRECT --to-ports" not in rules
    assert "NIK_MGL_PRE_TPROXY_V4 -p tcp -j TPROXY --on-port 7892" in rules
    assert "NIK_MGL_PRE_TPROXY_V4 -p udp -j TPROXY --on-port 7892" in rules
    assert "-p tcp --dport 53 -j NIK_MGL_PRE_TPROXY_V4" in rules
    assert "-p udp --dport 53 -j NIK_MGL_PRE_TPROXY_V4" in rules
    assert "-p tcp --dport 53 -j MARK --set-xmark 0x80/0xFF" in rules
    assert "-p udp --dport 53 -j MARK --set-xmark 0x80/0xFF" in rules
    assert "-i lo -p tcp -m mark --mark 0x80/0xFF -j NIK_MGL_PRE_TPROXY_V4" in rules
    assert "-i lo -p udp -m mark --mark 0x80/0xFF -j NIK_MGL_PRE_TPROXY_V4" in rules
    assert "--set-xmark 0x81/0xFF" not in rules

    router_only = tmp / "functions-v4-dns-tproxy-router-only.sh"
    router_text = text.replace("proxy.lan_proxy) _mock_value=1 ;;", "proxy.lan_proxy) _mock_value=0 ;;")
    write(router_only, router_text)
    router_script = tmp / "firewall-v4-dns-tproxy-router-only.sh"
    transformed_script(ROOT / "nikki/files/scripts/firewall_fw3.sh", router_script, router_only, include)
    router_rules = run(["/bin/sh", str(router_script), "render"], env=env)
    assert "-I PREROUTING 1 -j NIK_MGL_PRE_CTRL_V4" in router_rules
    assert "-I OUTPUT 1 -j NIK_MGL_OUT_MARK_V4" in router_rules
    assert "-i br-lan" not in router_rules


def test_ipv6_dns_only(tmp: Path, common: dict) -> None:
    runtime = tmp / "runtime-v6-dns-only"
    runtime.mkdir()
    (runtime / "config.yaml").write_text("test: true\n")
    include = tmp / "include-v6-dns-only.sh"
    write(
        include,
        f"""#!/bin/sh
TEMP_DIR="{runtime}"
RUN_PROFILE_PATH="{runtime / 'config.yaml'}"
APP_LOG_PATH="{runtime / 'app.log'}"
prepare_files() {{ mkdir -p "$TEMP_DIR"; : > "$APP_LOG_PATH"; }}
log() {{ :; }}
""",
    )

    functions = tmp / "functions-v6-dns-only.sh"
    functions_text = common["functions"].read_text()
    functions_text = functions_text.replace("proxy.ipv4_tcp_mode) _mock_value=redirect ;;", "proxy.ipv4_tcp_mode) _mock_value=disable ;;")
    functions_text = functions_text.replace("proxy.ipv4_udp_mode) _mock_value=tun ;;", "proxy.ipv4_udp_mode) _mock_value=disable ;;")
    functions_text = functions_text.replace("proxy.ipv6_tcp_mode) _mock_value=tun ;;", "proxy.ipv6_tcp_mode) _mock_value=disable ;;")
    functions_text = functions_text.replace("proxy.ipv6_udp_mode) _mock_value=tproxy ;;", "proxy.ipv6_udp_mode) _mock_value=disable ;;")
    functions_text = functions_text.replace("proxy.ipv4_dns_mode) _mock_value=redirect ;;", "proxy.ipv4_dns_mode) _mock_value=disable ;;")
    functions_text = functions_text.replace("proxy.ipv6_dns_mode) _mock_value=redirect ;;", "proxy.ipv6_dns_mode) _mock_value=tproxy ;;")
    write(functions, functions_text)

    bin_dir = tmp / "bin-v6-dns-only"
    shutil.copytree(common["bin"], bin_dir)
    write(
        bin_dir / "yq",
        """#!/bin/sh
for arg in "$@"; do
  case "$arg" in
    *redir-port*|*.dns.listen*) echo 'unexpected non-TPROXY listener lookup' >&2; exit 88 ;;
    *tproxy-port*) echo 7892; exit 0 ;;
  esac
done
echo '{}'
""",
    )

    script = tmp / "firewall-v6-dns-only.sh"
    transformed_script(ROOT / "nikki/files/scripts/firewall_fw3.sh", script, functions, include)
    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    rules = run(["/bin/sh", str(script), "render"], env=env)

    assert "# IPv4 / iptables-restore" not in rules
    assert "# IPv6 / ip6tables-restore" in rules
    assert "*nat" not in rules
    assert "REDIRECT" not in rules
    assert "NIK_NAT_" not in rules
    assert "-p tcp --dport 53 -j NIK_MGL_PRE_TPROXY_V6" in rules
    assert "-p udp --dport 53 -j NIK_MGL_PRE_TPROXY_V6" in rules
    assert "-p tcp --dport 53 -j MARK --set-xmark 0x80/0xFF" in rules
    assert "-p udp --dport 53 -j MARK --set-xmark 0x80/0xFF" in rules


def test_ipv6_dns_redirect_only(tmp: Path, common: dict) -> None:
    runtime = tmp / "runtime-v6-dns-redirect-only"
    runtime.mkdir()
    (runtime / "config.yaml").write_text("test: true\n")
    include = tmp / "include-v6-dns-redirect-only.sh"
    write(
        include,
        f"""#!/bin/sh
TEMP_DIR="{runtime}"
RUN_PROFILE_PATH="{runtime / 'config.yaml'}"
APP_LOG_PATH="{runtime / 'app.log'}"
prepare_files() {{ mkdir -p "$TEMP_DIR"; : > "$APP_LOG_PATH"; }}
log() {{ :; }}
""",
    )

    functions = tmp / "functions-v6-dns-redirect-only.sh"
    functions_text = common["functions"].read_text()
    functions_text = functions_text.replace("proxy.ipv4_tcp_mode) _mock_value=redirect ;;", "proxy.ipv4_tcp_mode) _mock_value=disable ;;")
    functions_text = functions_text.replace("proxy.ipv4_udp_mode) _mock_value=tun ;;", "proxy.ipv4_udp_mode) _mock_value=disable ;;")
    functions_text = functions_text.replace("proxy.ipv6_tcp_mode) _mock_value=tun ;;", "proxy.ipv6_tcp_mode) _mock_value=disable ;;")
    functions_text = functions_text.replace("proxy.ipv6_udp_mode) _mock_value=tproxy ;;", "proxy.ipv6_udp_mode) _mock_value=disable ;;")
    functions_text = functions_text.replace("proxy.ipv4_dns_mode) _mock_value=redirect ;;", "proxy.ipv4_dns_mode) _mock_value=disable ;;")
    write(functions, functions_text)

    bin_dir = tmp / "bin-v6-dns-redirect-only"
    shutil.copytree(common["bin"], bin_dir)
    write(
        bin_dir / "yq",
        """#!/bin/sh
for arg in "$@"; do
  case "$arg" in
    *.dns.listen*) echo '[::]:1053'; exit 0 ;;
    *redir-port*|*tproxy-port*|*.tun.device*|*.listeners*) echo 'unexpected non-DNS listener lookup' >&2; exit 88 ;;
  esac
done
echo '{}'
""",
    )

    script = tmp / "firewall-v6-dns-redirect-only.sh"
    transformed_script(ROOT / "nikki/files/scripts/firewall_fw3.sh", script, functions, include)
    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    rules = run(["/bin/sh", str(script), "render"], env=env)

    assert "# IPv4 / iptables-restore" not in rules
    assert "# IPv6 / ip6tables-restore" in rules
    assert "*nat" in rules
    assert "NIK_NAT_PRE_DNS_V6" in rules
    assert "NIK_NAT_OUT_DNS_V6" in rules
    assert re.search(r"NIK_NAT_PRE_DNS_V6 -i br-lan\s+-p udp --dport 53 -j REDIRECT --to-ports 1053", rules)
    assert re.search(r"NIK_NAT_PRE_DNS_V6 -i br-lan\s+-p tcp --dport 53 -j REDIRECT --to-ports 1053", rules)
    assert "-A NIK_NAT_OUT_DNS_V6 -m mark --mark 0x82/0xFF -j RETURN" in rules
    assert "-j TPROXY" not in rules
    assert "--set-xmark 0x81/0xFF" not in rules

    write(
        bin_dir / "yq",
        """#!/bin/sh
for arg in "$@"; do
  case "$arg" in
    *.dns.listen*) echo '0.0.0.0:1053'; exit 0 ;;
  esac
done
echo '{}'
""",
    )
    invalid = subprocess.run(
        ["/bin/sh", str(script), "render"],
        text=True,
        capture_output=True,
        env=env,
    )
    assert invalid.returncode != 0


def test_dns_tun_only(tmp: Path, common: dict) -> None:
    runtime = tmp / "runtime-dns-tun-only"
    runtime.mkdir()
    (runtime / "config.yaml").write_text("test: true\n")
    include = tmp / "include-dns-tun-only.sh"
    write(
        include,
        f"""#!/bin/sh
TEMP_DIR="{runtime}"
RUN_PROFILE_PATH="{runtime / 'config.yaml'}"
APP_LOG_PATH="{runtime / 'app.log'}"
prepare_files() {{ mkdir -p "$TEMP_DIR"; : > "$APP_LOG_PATH"; }}
log() {{ :; }}
""",
    )

    functions = tmp / "functions-dns-tun-only.sh"
    functions_text = common["functions"].read_text()
    functions_text = functions_text.replace("proxy.ipv4_tcp_mode) _mock_value=redirect ;;", "proxy.ipv4_tcp_mode) _mock_value=tproxy ;;")
    functions_text = functions_text.replace("proxy.ipv4_udp_mode) _mock_value=tun ;;", "proxy.ipv4_udp_mode) _mock_value=disable ;;")
    functions_text = functions_text.replace("proxy.ipv6_tcp_mode) _mock_value=tun ;;", "proxy.ipv6_tcp_mode) _mock_value=tproxy ;;")
    functions_text = functions_text.replace("proxy.ipv6_udp_mode) _mock_value=tproxy ;;", "proxy.ipv6_udp_mode) _mock_value=disable ;;")
    functions_text = functions_text.replace("proxy.ipv4_dns_mode) _mock_value=redirect ;;", "proxy.ipv4_dns_mode) _mock_value=tun ;;")
    functions_text = functions_text.replace("proxy.ipv6_dns_mode) _mock_value=redirect ;;", "proxy.ipv6_dns_mode) _mock_value=tun ;;")
    write(functions, functions_text)

    bin_dir = tmp / "bin-dns-tun-only"
    shutil.copytree(common["bin"], bin_dir)
    write(
        bin_dir / "yq",
        """#!/bin/sh
for arg in "$@"; do
  case "$arg" in
    *redir-port*|*.dns.listen*) echo 'unexpected REDIRECT/DNS listener lookup' >&2; exit 88 ;;
    *tproxy-port*) echo 7892; exit 0 ;;
    *.tun.device*|*.listeners*) echo nikki; exit 0 ;;
  esac
done
echo '{}'
""",
    )

    script = tmp / "firewall-dns-tun-only.sh"
    transformed_script(ROOT / "nikki/files/scripts/firewall_fw3.sh", script, functions, include)
    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    rules = run(["/bin/sh", str(script), "render"], env=env)

    assert "# IPv4 / iptables-restore" in rules
    assert "# IPv6 / ip6tables-restore" in rules
    ipv6_rules = rules.split("# IPv6 / ip6tables-restore", 1)[1]
    assert "*nat" not in ipv6_rules
    assert "REDIRECT" not in rules
    assert "--dport 53 -j NIK_MGL_PRE_TPROXY_V4" not in rules
    assert "--dport 53 -j NIK_MGL_PRE_TPROXY_V6" not in rules
    assert "--dport 53 -j MARK --set-xmark 0x80/0xFF" not in rules
    for family in ("V4", "V6"):
        assert f"-A NIK_MGL_PRE_TUN_{family} -j MARK --set-xmark 0x81/0xFF" in rules
        assert re.search(
            rf"-A NIK_MGL_PRE_CTRL_{family} .* -p udp --dport 53 -j NIK_MGL_PRE_TUN_{family}\n"
            rf"-A NIK_MGL_PRE_CTRL_{family} .* -p udp --dport 53 -j RETURN",
            rules,
        )
        assert re.search(
            rf"-A NIK_MGL_PRE_CTRL_{family} .* -p tcp --dport 53 -j NIK_MGL_PRE_TUN_{family}\n"
            rf"-A NIK_MGL_PRE_CTRL_{family} .* -p tcp --dport 53 -j RETURN",
            rules,
        )
        assert re.search(rf"-A NIK_MGL_OUT_TUN_{family} .* -p udp --dport 53 -j MARK --set-xmark 0x81/0xFF", rules)
        assert re.search(rf"-A NIK_MGL_OUT_TUN_{family} .* -p tcp --dport 53 -j MARK --set-xmark 0x81/0xFF", rules)
        dns_jump = re.search(rf"-A NIK_MGL_PRE_CTRL_{family} -i br-lan .*--dport 53 -j NIK_MGL_PRE_TUN_{family}", rules)
        general_tproxy = re.search(rf"-A NIK_MGL_PRE_CTRL_{family} -i br-lan .* -j NIK_MGL_PRE_TPROXY_{family}", rules)
        assert dns_jump and general_tproxy
        assert dns_jump.start() < general_tproxy.start()

def test_firewall_apply(tmp: Path, common: dict) -> None:
    runtime = tmp / "runtime-apply"
    runtime.mkdir()
    (runtime / "config.yaml").write_text("test: true\n")
    include = tmp / "include-apply.sh"
    write(
        include,
        f"""#!/bin/sh
TEMP_DIR="{runtime}"
RUN_PROFILE_PATH="{runtime / 'config.yaml'}"
APP_LOG_PATH="{runtime / 'app.log'}"
prepare_files() {{ mkdir -p "$TEMP_DIR"; : > "$APP_LOG_PATH"; }}
log() {{ printf '[%s] %s\\n' "$1" "$2" >> "$APP_LOG_PATH"; }}
""",
    )
    script = tmp / "firewall-apply.sh"
    transformed_script(ROOT / "nikki/files/scripts/firewall_fw3.sh", script, common["functions"], include)

    capture = tmp / "capture"
    capture.mkdir()
    xtables_mock = """#!/bin/sh
case " $* " in
  *" -C "*) exit 1 ;;
  *) exit 0 ;;
esac
"""
    write(common["bin"] / "iptables", xtables_mock)
    write(common["bin"] / "ip6tables", xtables_mock)
    write(
        common["bin"] / "iptables-restore",
        f"""#!/bin/sh
cat > "{capture / 'iptables.rules'}"
""",
    )
    write(
        common["bin"] / "ip6tables-restore",
        f"""#!/bin/sh
cat > "{capture / 'ip6tables.rules'}"
""",
    )
    write(
        common["bin"] / "ipset",
        f"""#!/bin/sh
if [ "$1" = restore ]; then
    cat > "{capture / 'ipset.rules'}"
fi
exit 0
""",
    )
    china4 = tmp / "china4.txt"
    china6 = tmp / "china6.txt"
    china4.write_text("1.0.1.0/24\n")
    china6.write_text("2400:3200::/32\n")

    env = os.environ.copy()
    env["PATH"] = f"{common['bin']}:{env['PATH']}"
    env["LOCK_DIR"] = str(tmp / "nikki-fw.lock")
    env["CHINA_IP4_FILE"] = str(china4)
    env["CHINA_IP6_FILE"] = str(china6)
    run(["/bin/sh", str(script), "apply"], env=env)

    rules4 = (capture / "iptables.rules").read_text()
    rules6 = (capture / "ip6tables.rules").read_text()
    sets = (capture / "ipset.rules").read_text()
    assert "NIK_MGL_PRE_TPROXY_V4" in rules4
    assert "NIK_MGL_PRE_TUN_V4" in rules4
    assert "NIK_FLT_IN_TUN_V4" in rules4
    assert "NIK_FLT_FWD_TUN_V4" in rules4
    assert "NIK_MGL_PRE_TPROXY_V6" in rules6
    assert "NIK_MGL_PRE_TUN_V6" in rules6
    assert "NIK_FLT_IN_TUN_V6" in rules6
    assert "NIK_FLT_FWD_TUN_V6" in rules6
    assert "--set-xmark 0x81/0xFF" in rules4
    assert "--set-xmark 0x81/0xFF" in rules6
    assert "*nat" in rules6
    assert "NIK_NAT_PRE_DNS_V6" in rules6
    assert "NIK_NAT_OUT_DNS_V6" in rules6
    assert "REDIRECT --to-ports 1053" in rules6
    assert "-p tcp -j TPROXY --on-port 7892" not in rules6
    assert "-p udp -j TPROXY --on-port 7892" in rules6
    assert "family inet6" in sets
    assert "add nik_reserved_v6_t ::1/128 -exist" in sets
    assert "add nik_china_v6_t 2400:3200::/32 -exist" in sets
    assert "add nik_china_v4_t 1.0.1.0/24 -exist" in sets

def test_tun_policy_routes(tmp: Path) -> None:
    include = tmp / "init-include.sh"
    write(include, "#!/bin/sh\n")
    init_src = (ROOT / "nikki/files/nikki.init").read_text()
    init_src = init_src.replace(
        '. "$IPKG_INSTROOT/etc/nikki/scripts/include.sh"',
        f'. "{include}"',
        1,
    )
    init_script = tmp / "nikki-init-functions.sh"
    write(init_script, init_src)

    bin_dir = tmp / "route-bin"
    bin_dir.mkdir()
    log_path = tmp / "ip.log"
    ip_mock = (
        "#!/bin/sh\n"
        f"printf '%s\\n' \"$*\" >> \"{log_path}\"\n"
        "case \" $* \" in\n"
        "  *\" rule del \"*|*\" route del \"*) exit 1 ;;\n"
        "esac\n"
        "exit 0\n"
    )
    write(bin_dir / "ip", ip_mock)
    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    run(
        [
            "/bin/sh",
            "-c",
            f'. "{init_script}"; '
            'add_tun_policy_route 4 0x81 0xFF 1025 81 nikki; '
            'add_tun_policy_route 6 0x81 0xFF 1025 81 nikki',
        ],
        env=env,
    )
    calls = log_path.read_text()
    assert "-4 route add default dev nikki table 81" in calls
    assert "-4 rule add pref 1025 fwmark 0x81/0xFF table 81" in calls
    assert "-6 route add default dev nikki table 81" in calls
    assert "-6 rule add pref 1025 fwmark 0x81/0xFF table 81" in calls


def make_fake_core(path: Path, version: str) -> None:
    source = path.with_suffix(path.suffix + ".c")
    source.write_text(
        "#include <stdio.h>\n"
        "#include <string.h>\n"
        "int main(int argc, char **argv) {\n"
        f'  if (argc > 1 && strcmp(argv[1], "-v") == 0) {{ puts("Mihomo Meta {version} linux amd64"); return 0; }}\n'
        "  return 0;\n"
        "}\n"
    )
    run(["cc", "-O2", "-o", str(path), str(source)])
    path.chmod(0o755)


def make_gzip(source: Path, destination: Path) -> None:
    import gzip
    with source.open("rb") as src, gzip.open(destination, "wb") as dst:
        shutil.copyfileobj(src, dst)


def make_core_tar(source: Path, destination: Path) -> None:
    with tarfile.open(destination, "w:gz") as tf:
        tf.add(source, arcname="clash")



def core_updater_function_helper(tmp: Path, body: str) -> Path:
    source = (ROOT / "nikki/files/scripts/core_update.sh").read_text()
    marker = 'case "${1:-status}" in\n'
    index = source.rfind(marker)
    assert index > 0
    helper = tmp / "core-updater-functions.sh"
    write(helper, source[:index] + body + "\n")
    return helper


def test_core_space_policy(tmp: Path) -> None:
    helper = core_updater_function_helper(
        tmp,
        r'''
available_kb() { printf '%s' "$TEST_DISK_KB"; }
mem_available_kb() { printf '%s' "$TEST_MEM_KB"; }
if choose_download_root "$TEST_HAS_CORE"; then
    printf '%s|%s\n' "$DOWNLOAD_ROOT" "$DOWNLOAD_PREDELETE"
else
    exit 1
fi
''',
    )

    def check(has_core: int, disk_mib: int, mem_mib: int, success: bool, expected: str = "") -> None:
        env = os.environ.copy()
        env.update({
            "CORE_DIR": "/core",
            "TEMP_ROOT": "/tmp",
            "TEST_HAS_CORE": str(has_core),
            "TEST_DISK_KB": str(disk_mib * 1024),
            "TEST_MEM_KB": str(mem_mib * 1024),
        })
        result = subprocess.run(["/bin/sh", str(helper)], text=True, capture_output=True, env=env)
        assert (result.returncode == 0) is success
        if success:
            assert result.stdout.strip() == expected

    check(0, 49, 100, False)
    check(0, 70, 0, True, "/core|0")
    check(0, 60, 26, True, "/tmp|0")
    check(0, 60, 25, False)
    check(1, 19, 19, False)
    check(1, 20, 10, True, "/core|1")
    check(1, 10, 20, True, "/tmp|0")
    check(1, 30, 0, True, "/core|0")


def test_firmware_core_symlink(tmp: Path) -> None:
    runtime = tmp / "firmware-core"
    core_dir = runtime / "managed"
    home_dir = runtime / "etc"
    temp_dir = runtime / "tmp"
    core_dir.mkdir(parents=True)
    home_dir.mkdir()
    temp_dir.mkdir()
    firmware = runtime / "firmware-mihomo"
    make_fake_core(firmware, "v9.9.9")

    source = (ROOT / "nikki/files/scripts/core_update.sh").read_text()
    source = source.replace(
        "for path in /usr/libexec/mihomo /usr/bin/mihomo; do",
        f"for path in {firmware}; do",
        1,
    )
    source = source.replace(
        'case "$target" in /usr/libexec/mihomo|/usr/bin/mihomo)',
        f'case "$target" in {firmware})',
        1,
    )
    updater = runtime / "core_update.sh"
    write(updater, source)
    active = core_dir / "mihomo"
    env = os.environ.copy()
    env.update({
        "HOME_DIR": str(home_dir), "CORE_DIR": str(core_dir), "CORE_ACTIVE": str(active),
        "STATE_FILE": str(home_dir / "state"), "LOCK_DIR": str(runtime / "lock"),
        "TEMP_ROOT": str(temp_dir), "UCI_BIN": str(runtime / "missing-uci"),
        "OPKG_BIN": str(runtime / "missing-opkg"), "APK_BIN": str(runtime / "missing-apk"),
    })
    run(["/bin/sh", str(updater), "migrate"], env=env)
    assert active.is_symlink()
    assert active.resolve() == firmware.resolve()
    status = run(["/bin/sh", str(updater), "status"], env=env)
    assert "core_origin\tfirmware" in status
    assert "core_size_bytes\t0" in status
    run(["/bin/sh", str(updater), "delete-current"], env=env)
    status = run(["/bin/sh", str(updater), "status"], env=env)
    assert "当前为固件内置核心，不占用可写空间，无法通过删除释放更新空间" in status
    assert active.is_symlink()


def test_core_update(tmp: Path) -> None:
    runtime = tmp / "core-update"
    bin_dir = runtime / "bin"
    core_dir = runtime / "core"
    home_dir = runtime / "etc"
    temp_dir = runtime / "tmp"
    bin_dir.mkdir(parents=True)
    core_dir.mkdir()
    home_dir.mkdir()
    temp_dir.mkdir()

    active = core_dir / "mihomo"
    download = runtime / "download-core"
    curl_log = runtime / "curl.log"
    make_fake_core(active, "v1.0.0")
    make_fake_core(download, "v1.1.0")

    direct_url = "https://example.invalid/releases/v1.1.0/mihomo-linux-amd64-compatible-v1.1.0"
    write(
        bin_dir / "uci",
        f'''#!/bin/sh
case "$3" in
  nikki.core_update.source_type) echo direct ;;
  nikki.core_update.direct_url) echo '{direct_url}' ;;
  *) exit 1 ;;
esac
''',
    )
    write(
        bin_dir / "curl",
        f'''#!/bin/sh
out=''
url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -A|--connect-timeout|--max-time|--retry|--speed-limit|--speed-time|--range) shift 2 ;;
    -f|-L|-s|-S|-sS) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >> "{curl_log}"
[ "$url" = '{direct_url}' ] || exit 22
[ "$out" = /dev/null ] && exit 0
cp "{download}" "$out"
''',
    )
    write(bin_dir / "opkg", "#!/bin/sh\nprintf '%s\\n' 'arch all 1' 'arch x86_64 10'\n")
    write(bin_dir / "uname", "#!/bin/sh\necho x86_64\n")
    write(bin_dir / "service", "#!/bin/sh\ncase \"$1\" in running) exit 1 ;; stop|restart) exit 0 ;; esac\n")

    updater = ROOT / "nikki/files/scripts/core_update.sh"
    env = os.environ.copy()
    env.update(
        {
            "HOME_DIR": str(home_dir),
            "CORE_DIR": str(core_dir),
            "CORE_ACTIVE": str(active),
            "STATE_FILE": str(home_dir / "core-update.state"),
            "LOCK_DIR": str(runtime / "update.lock"),
            "TEMP_ROOT": str(temp_dir),
            "UCI_BIN": str(bin_dir / "uci"),
            "CURL_BIN": str(bin_dir / "curl"),
            "OPKG_BIN": str(bin_dir / "opkg"),
            "APK_BIN": str(bin_dir / "missing-apk"),
            "UNAME_BIN": str(bin_dir / "uname"),
            "SERVICE_BIN": str(bin_dir / "service"),
        }
    )

    arches = run(["/bin/sh", str(updater), "architectures"], env=env).splitlines()
    assert arches == ["official\tamd64-compatible", "shellcrash\tamd64"]

    assert run(["/bin/sh", str(updater), "check"], env=env).strip() == "v1.1.0"
    installed = run(["/bin/sh", str(updater), "update"], env=env).strip()
    assert installed == "v1.1.0"
    assert run([str(active), "-v"]).split()[2] == "v1.1.0"
    assert not (core_dir / "mihomo.prev").exists()
    assert curl_log.read_text().splitlines() == [direct_url, direct_url, direct_url]

    download.write_text("not an ELF core")
    download.chmod(0o755)
    failed = subprocess.run(["/bin/sh", str(updater), "update"], text=True, capture_output=True, env=env)
    assert failed.returncode != 0
    assert "下载的内核文件已损坏" in failed.stderr
    assert not active.exists()

    make_fake_core(active, "v1.0.0")
    run(["/bin/sh", str(updater), "delete-current"], env=env)
    status = run(["/bin/sh", str(updater), "status"], env=env)
    assert "status\tcore_deleted" in status
    assert "当前内核已删除，已释放约" in status
    assert not active.exists()


def test_official_source_channels(tmp: Path) -> None:
    tag = "v1.2.3"
    asset_name = "mihomo-linux-amd64-compatible-v1.2.3.gz"
    original_url = f"https://github.com/MetaCubeX/mihomo/releases/download/{tag}/{asset_name}"
    api_url = "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
    proxy_api_url = "https://gh-proxy.com/" + api_url
    channel_urls = {
        "proxy": "https://gh-proxy.com/" + original_url,
        "proxynet": "https://ghproxy.net/" + original_url,
        "github": original_url,
    }

    def run_case(name: str, preset: str, direct_api_ok: bool, success_channel: str):
        runtime = tmp / f"official-{name}"
        bin_dir = runtime / "bin"
        core_dir = runtime / "core"
        home_dir = runtime / "etc"
        temp_dir = runtime / "tmp"
        bin_dir.mkdir(parents=True)
        core_dir.mkdir()
        home_dir.mkdir()
        temp_dir.mkdir()

        active = core_dir / "mihomo"
        binary = runtime / "download-core"
        download = runtime / "download-core.gz"
        release_json = runtime / "release.json"
        curl_log = runtime / "curl.log"
        make_fake_core(binary, tag)
        make_gzip(binary, download)
        release_json.write_text(json.dumps({"tag_name": tag, "assets": [{"name": asset_name, "browser_download_url": original_url}]}))

        write(
            bin_dir / "uci",
            f'''#!/bin/sh
case "$3" in
  nikki.core_update.source_type) echo official ;;
  nikki.core_update.official_repository) echo MetaCubeX/mihomo ;;
  nikki.core_update.official_preset) echo {preset} ;;
  *) exit 1 ;;
esac
''',
        )
        write(
            bin_dir / "yq",
            r'''#!/bin/sh
args="$*"
for last do :; done
case "$args" in
  *'.tag_name // ""'*) sed -n 's/.*"tag_name": "\([^"]*\)".*/\1/p' "$last" ;;
  *'.assets | length'*) grep -o '"browser_download_url"' "$last" | wc -l | tr -d ' ' ;;
  *'.assets[]'*'.browser_download_url'*)
    grep -Fq "\"name\": \"$ASSET_NAME\"" "$last" || exit 0
    sed -n 's/.*"browser_download_url": "\([^"]*\)".*/\1/p' "$last"
    ;;
  *) exit 1 ;;
esac
''',
        )
        direct_api_action = f'[ -n "$out" ] || exit 22; cp "{release_json}" "$out"' if direct_api_ok else "exit 28"
        success_url = channel_urls[success_channel]
        write(
            bin_dir / "curl",
            f'''#!/bin/sh
out=''
url=''
max_time=''
range='0'
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    --max-time) max_time="$2"; shift 2 ;;
    --range) range='1'; shift 2 ;;
    -A|--connect-timeout|--retry|--speed-limit|--speed-time) shift 2 ;;
    -f|-L|-s|-S|-sS) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s|%s|%s\n' "$max_time" "$range" "$url" >> "{curl_log}"
case "$url" in
  {api_url}) {direct_api_action} ;;
  {proxy_api_url}) [ -n "$out" ] || exit 22; cp "{release_json}" "$out" ;;
  {success_url})
    [ "$out" = /dev/null ] && exit 0
    [ -n "$out" ] || exit 22
    cp "{download}" "$out"
    ;;
  *) exit 22 ;;
esac
''',
        )
        write(bin_dir / "opkg", "#!/bin/sh\nprintf '%s\\n' 'arch all 1' 'arch x86_64 10'\n")
        write(bin_dir / "uname", "#!/bin/sh\necho x86_64\n")
        write(bin_dir / "service", "#!/bin/sh\nexit 1\n")

        updater = ROOT / "nikki/files/scripts/core_update.sh"
        env = os.environ.copy()
        env.update({
            "HOME_DIR": str(home_dir), "CORE_DIR": str(core_dir), "CORE_ACTIVE": str(active),
            "STATE_FILE": str(home_dir / "core-update.state"), "LOCK_DIR": str(runtime / "update.lock"),
            "TEMP_ROOT": str(temp_dir), "UCI_BIN": str(bin_dir / "uci"), "CURL_BIN": str(bin_dir / "curl"),
            "YQ_BIN": str(bin_dir / "yq"), "OPKG_BIN": str(bin_dir / "opkg"),
            "APK_BIN": str(bin_dir / "missing-apk"), "UNAME_BIN": str(bin_dir / "uname"),
            "SERVICE_BIN": str(bin_dir / "service"),
        })
        assert run(["/bin/sh", str(updater), "update"], env=env).strip() == tag
        assert run([str(active), "-v"]).split()[2] == tag
        state = (home_dir / "core-update.state").read_text()
        assert "source=MetaCubeX 官方最新发布" in state
        return curl_log.read_text().splitlines()

    auto_calls = run_case("auto", "auto", False, "proxynet")
    assert auto_calls[:4] == [
        f"10|0|{api_url}", f"10|0|{proxy_api_url}",
        f"5|1|{channel_urls['proxy']}", f"5|1|{channel_urls['proxynet']}",
    ]
    assert auto_calls[4].endswith(f"|0|{channel_urls['proxynet']}")
    assert 1 <= int(auto_calls[4].split('|', 1)[0]) <= 300
    assert f"5|1|{channel_urls["github"]}" not in auto_calls

    proxy_calls = run_case("proxy", "proxy", True, "proxy")
    assert proxy_calls[:2] == [f"10|0|{api_url}", f"5|1|{channel_urls['proxy']}"]
    assert proxy_calls[2].endswith(f"|0|{channel_urls['proxy']}")

    proxynet_calls = run_case("proxynet", "proxynet", True, "proxynet")
    assert proxynet_calls[:2] == [f"10|0|{api_url}", f"5|1|{channel_urls['proxynet']}"]
    assert proxynet_calls[2].endswith(f"|0|{channel_urls['proxynet']}")

    github_calls = run_case("github", "github", True, "github")
    assert github_calls[:2] == [f"10|0|{api_url}", f"5|1|{channel_urls['github']}"]
    assert github_calls[2].endswith(f"|0|{channel_urls['github']}")


def test_shellcrash_repository_update(tmp: Path) -> None:
    runtime = tmp / "repository-update"
    bin_dir = runtime / "bin"
    core_dir = runtime / "core"
    home_dir = runtime / "etc"
    temp_dir = runtime / "tmp"
    bin_dir.mkdir(parents=True)
    core_dir.mkdir()
    home_dir.mkdir()
    temp_dir.mkdir()

    active = core_dir / "mihomo"
    binary = runtime / "download-core"
    download = runtime / "download-core.tar.gz"
    curl_log = runtime / "curl.log"
    make_fake_core(binary, "v1.2.3")
    make_core_tar(binary, download)

    write(
        bin_dir / "uci",
        '''#!/bin/sh
case "$3" in
  nikki.core_update.source_type) echo repository ;;
  nikki.core_update.repository_preset) echo custom ;;
  nikki.core_update.repository_url) echo 'https://mirror.invalid/root/' ;;
  *) exit 1 ;;
esac
''',
    )
    expected_asset = "https://mirror.invalid/root/bin/meta/clash-linux-amd64.tar.gz"
    write(
        bin_dir / "curl",
        f'''#!/bin/sh
out=''; url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -A|--connect-timeout|--max-time|--retry|--speed-limit|--speed-time|--range) shift 2 ;;
    -f|-L|-s|-S|-sS) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >> "{curl_log}"
case "$url" in
  https://mirror.invalid/root/bin/version) echo 'meta_v=v1.2.3 versionsh=1.9.5' ;;
  {expected_asset}) [ "$out" = /dev/null ] && exit 0; cp "{download}" "$out" ;;
  *) exit 22 ;;
esac
''',
    )
    write(bin_dir / "opkg", "#!/bin/sh\nprintf '%s\\n' 'arch all 1' 'arch x86_64 10'\n")
    write(bin_dir / "uname", "#!/bin/sh\necho x86_64\n")
    write(bin_dir / "service", "#!/bin/sh\nexit 1\n")

    updater = ROOT / "nikki/files/scripts/core_update.sh"
    env = os.environ.copy()
    env.update({
        "HOME_DIR": str(home_dir), "CORE_DIR": str(core_dir), "CORE_ACTIVE": str(active),
        "STATE_FILE": str(home_dir / "core-update.state"), "LOCK_DIR": str(runtime / "update.lock"),
        "TEMP_ROOT": str(temp_dir), "UCI_BIN": str(bin_dir / "uci"), "CURL_BIN": str(bin_dir / "curl"),
        "OPKG_BIN": str(bin_dir / "opkg"), "APK_BIN": str(bin_dir / "missing-apk"),
        "UNAME_BIN": str(bin_dir / "uname"), "SERVICE_BIN": str(bin_dir / "service"),
    })

    assert run(["/bin/sh", str(updater), "update"], env=env).strip() == "v1.2.3"
    assert run([str(active), "-v"]).split()[2] == "v1.2.3"
    assert curl_log.read_text().splitlines() == [
        "https://mirror.invalid/root/bin/version", expected_asset, expected_asset,
    ]


def test_shellcrash_automatic_https_fallback(tmp: Path) -> None:
    runtime = tmp / "repository-auto-fallback"
    bin_dir = runtime / "bin"
    core_dir = runtime / "core"
    home_dir = runtime / "etc"
    temp_dir = runtime / "tmp"
    bin_dir.mkdir(parents=True)
    core_dir.mkdir()
    home_dir.mkdir()
    temp_dir.mkdir()

    active = core_dir / "mihomo"
    binary = runtime / "download-core"
    download = runtime / "download-core.tar.gz"
    curl_log = runtime / "curl.log"
    make_fake_core(binary, "v1.19.17")
    make_core_tar(binary, download)

    write(bin_dir / "uci", "#!/bin/sh\ncase \"$3\" in nikki.core_update.source_type) echo repository;; nikki.core_update.repository_preset) echo auto;; *) exit 1;; esac\n")
    first_base = "https://testingcf.jsdelivr.net/gh/juewuy/ShellCrash@dev"
    selected_base = "https://cdn.jsdelivr.net/gh/juewuy/ShellCrash@dev"
    selected_asset = selected_base + "/bin/meta/clash-linux-amd64.tar.gz"
    write(
        bin_dir / "curl",
        f'''#!/bin/sh
out=''; url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -A|--connect-timeout|--max-time|--retry|--speed-limit|--speed-time|--range) shift 2 ;;
    -f|-L|-s|-S|-sS) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >> "{curl_log}"
case "$url" in
  {first_base}/bin/version) echo 'meta_v=v1.19.17' ;;
  {first_base}/bin/meta/clash-linux-amd64.tar.gz) exit 22 ;;
  {selected_base}/bin/version) echo 'meta_v=v1.19.17' ;;
  {selected_asset}) [ "$out" = /dev/null ] && exit 0; cp "{download}" "$out" ;;
  *) exit 22 ;;
esac
''',
    )
    write(bin_dir / "opkg", "#!/bin/sh\necho 'arch x86_64 10'\n")
    write(bin_dir / "uname", "#!/bin/sh\necho x86_64\n")
    write(bin_dir / "service", "#!/bin/sh\nexit 1\n")

    updater = ROOT / "nikki/files/scripts/core_update.sh"
    env = os.environ.copy()
    env.update({
        "HOME_DIR": str(home_dir), "CORE_DIR": str(core_dir), "CORE_ACTIVE": str(active),
        "STATE_FILE": str(home_dir / "core-update.state"), "LOCK_DIR": str(runtime / "update.lock"),
        "TEMP_ROOT": str(temp_dir), "UCI_BIN": str(bin_dir / "uci"), "CURL_BIN": str(bin_dir / "curl"),
        "OPKG_BIN": str(bin_dir / "opkg"), "APK_BIN": str(bin_dir / "missing-apk"),
        "UNAME_BIN": str(bin_dir / "uname"), "SERVICE_BIN": str(bin_dir / "service"),
    })
    assert run(["/bin/sh", str(updater), "update"], env=env).strip() == "v1.19.17"
    urls = curl_log.read_text().splitlines()
    assert urls == [
        first_base + "/bin/version",
        first_base + "/bin/meta/clash-linux-amd64.tar.gz",
        selected_base + "/bin/version",
        selected_asset,
        selected_asset,
    ]
    assert not any(url.startswith("https://gh.jwsc.eu.org") for url in urls)


def test_core_source_change_status(tmp: Path) -> None:
    runtime = tmp / "core-source-change"
    bin_dir = runtime / "bin"
    core_dir = runtime / "core"
    home_dir = runtime / "etc"
    temp_dir = runtime / "tmp"
    bin_dir.mkdir(parents=True)
    core_dir.mkdir(); home_dir.mkdir(); temp_dir.mkdir()
    selected = runtime / "selected"
    selected.write_text("a")
    write(bin_dir / "uci", f'''#!/bin/sh
case "$3" in
 nikki.core_update.source_type) echo direct ;;
 nikki.core_update.direct_url) cat "{selected}" ;;
 *) exit 1 ;;
esac
''')
    write(bin_dir / "opkg", "#!/bin/sh\necho 'arch x86_64 10'\n")
    write(bin_dir / "uname", "#!/bin/sh\necho x86_64\n")
    updater = ROOT / "nikki/files/scripts/core_update.sh"
    env = os.environ.copy()
    env.update({"HOME_DIR": str(home_dir), "CORE_DIR": str(core_dir), "CORE_ACTIVE": str(core_dir / "mihomo"),
                "STATE_FILE": str(home_dir / "state"), "LOCK_DIR": str(runtime / "lock"), "TEMP_ROOT": str(temp_dir),
                "UCI_BIN": str(bin_dir / "uci"), "OPKG_BIN": str(bin_dir / "opkg"), "APK_BIN": str(bin_dir / "none"),
                "UNAME_BIN": str(bin_dir / "uname")})
    (home_dir / "state").write_text("checked_source_key=direct|a\nlatest_version=v1.0.0\nlast_status=checked\nsource=old\n")
    selected.write_text("b")
    status = run(["/bin/sh", str(updater), "status"], env=env)
    assert "status\tsource_changed" in status
    assert "latest_version\t\n" in status
    assert "source\t精确直链: b" in status


def test_core_archive_extraction(tmp: Path) -> None:
    source = (ROOT / "nikki/files/scripts/core_update.sh").read_text()
    marker = 'case "${1:-status}" in\n'
    index = source.rfind(marker)
    assert index > 0
    source = source[:index] + 'extract_to_active "$1" "$2"\n'
    helper = tmp / "extract-core.sh"
    write(helper, source)
    temp_root = tmp / "extract-temp"
    temp_root.mkdir()
    core = tmp / "mihomo"
    make_fake_core(core, "v9.9.9")
    archive = tmp / "core.tar.gz"
    with tarfile.open(archive, "w:gz") as tf:
        directory = tarfile.TarInfo("nested directory/")
        directory.type = tarfile.DIRTYPE
        directory.mode = 0o755
        tf.addfile(directory)
        tf.add(core, arcname="nested directory/mihomo")
    output = tmp / "extracted-core"
    env = os.environ.copy()
    env["TEMP_ROOT"] = str(temp_root)
    env["CORE_ACTIVE"] = str(output)
    run(["/bin/sh", str(helper), str(archive), "core.tar.gz"], env=env)
    assert output.read_bytes() == core.read_bytes()

    malicious = tmp / "malicious.tar.gz"
    payload = b"malicious"
    with tarfile.open(malicious, "w:gz") as tf:
        import io
        info = tarfile.TarInfo("../mihomo")
        info.size = len(payload)
        tf.addfile(info, io.BytesIO(payload))
    rejected = subprocess.run(
        ["/bin/sh", str(helper), str(malicious), "malicious.tar.gz"],
        text=True,
        capture_output=True,
        env=env,
    )
    assert rejected.returncode != 0


def test_rpc_transactional_write(tmp: Path) -> None:
    runtime = tmp / "rpc-write"
    profiles = runtime / "profiles"
    profiles.mkdir(parents=True)
    jshn = make_jshn_mock(runtime)
    source = (ROOT / "luci-app-nikki/root/usr/libexec/nikki-rpc").read_text()
    source = source.replace('. /usr/share/libubox/jshn.sh', f'. "{jshn}"', 1)
    source = source.replace('/etc/nikki/profiles/*.yaml', f'{profiles}/*.yaml')
    source = source.replace('/etc/nikki/profiles/*.yml', f'{profiles}/*.yml')
    source = source.replace('TMP_DIR="/var/run/nikki"', f'TMP_DIR="{runtime / "tmp"}"', 1)
    helper = runtime / "nikki-rpc"
    write(helper, source)
    target = profiles / "test.yaml"
    target.write_text("old")
    env = os.environ.copy()
    env["JSHN_OPS"] = str(runtime / "jshn-ops.tsv")

    first = json.loads(run(["/bin/sh", str(helper), "write-file", str(target), "new-", "0", "644", "0"], env=env))
    assert first["success"] is True
    assert target.read_text() == "old"
    assert Path(str(target) + ".nikki-write").read_text() == "new-"

    final = json.loads(run(["/bin/sh", str(helper), "write-file", str(target), "content", "1", "644", "1"], env=env))
    assert final["success"] is True
    assert target.read_text() == "new-content"
    assert not Path(str(target) + ".nikki-write").exists()

    legacy = json.loads(run(["/bin/sh", str(helper), "write-file", str(target), "legacy", "0", "600"], env=env))
    assert legacy["success"] is True
    assert target.read_text() == "legacy"

    rejected = subprocess.run(
        ["/bin/sh", str(helper), "write-file", str(target), "x", "2", "644", "1"],
        text=True,
        capture_output=True,
        env=env,
    )
    assert rejected.returncode != 0
    assert target.read_text() == "legacy"


def test_rpc_ipv6_wildcard(tmp: Path) -> None:
    runtime = tmp / "rpc-ipv6"
    bin_dir = runtime / "bin"
    bin_dir.mkdir(parents=True)
    profile = runtime / "config.yaml"
    profile.write_text("external-controller: http://[::]:9090\n")
    curl_log = runtime / "curl.log"
    jshn = runtime / "jshn.sh"
    write(jshn, "#!/bin/sh\n")

    write(
        bin_dir / "yq",
        """#!/bin/sh
for arg in "$@"; do
  case "$arg" in
    *external-controller-tls*) echo ''; exit 0 ;;
    *external-controller*) echo 'http://[::]:9090'; exit 0 ;;
    *secret*) echo ''; exit 0 ;;
  esac
done
cat
""",
    )
    write(
        bin_dir / "curl",
        f"""#!/bin/sh
printf '%s\\n' "$*" > "{curl_log}"
printf '{{}}\\n'
""",
    )

    source = (ROOT / "luci-app-nikki/root/usr/libexec/nikki-rpc").read_text()
    source = source.replace('. /usr/share/libubox/jshn.sh', f'. "{jshn}"', 1)
    source = source.replace('RUN_PROFILE="$HOME_DIR/run/config.yaml"', f'RUN_PROFILE="{profile}"', 1)
    source = source.replace('TMP_DIR="/var/run/nikki"', f'TMP_DIR="{runtime / "tmp"}"', 1)
    helper = runtime / "nikki-rpc"
    write(helper, source)
    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    output = run(["/bin/sh", str(helper), "api", "GET", "/version", "", ""], env=env)
    assert json.loads(output) == {}
    call = curl_log.read_text()
    assert "http://127.0.0.1:9090/version" in call
    assert "http://[::]:9090/version" not in call



def test_rpc_firewall_backend_detection(tmp: Path) -> None:
    runtime = tmp / "rpc-firewall"
    bin_dir = runtime / "bin"
    bin_dir.mkdir(parents=True)
    jshn = make_jshn_mock(runtime)
    source = (ROOT / "luci-app-nikki/root/usr/libexec/nikki-rpc").read_text()
    source = source.replace('. /usr/share/libubox/jshn.sh', f'. "{jshn}"', 1)
    source = source.replace('TMP_DIR="/var/run/nikki"', f'TMP_DIR="{runtime / "tmp"}"', 1)
    helper = runtime / "nikki-rpc"
    write(helper, source)
    env = os.environ.copy()
    env["PATH"] = f"{bin_dir}:{env['PATH']}"
    env["JSHN_OPS"] = str(runtime / "jshn-ops.tsv")

    def command(name: str, body: str) -> None:
        write(bin_dir / name, "#!/bin/sh\n" + body)

    # Active firewall4: canonical inet/fw4 table exists.
    command("fw4", "exit 0\n")
    command("nft", "[ \"$*\" = \"list table inet fw4\" ] && exit 0\nexit 1\n")
    result = json.loads(run(["/bin/sh", str(helper), "firewall-backend"], env=env))
    assert result["backend"] == "fw4"

    # Active firewall3: characteristic fw3 zone chain exists.
    (bin_dir / "fw4").unlink()
    (bin_dir / "nft").unlink()
    command("fw3", "exit 0\n")
    command("iptables-save", "printf '%s\\n' ':zone_lan_input - [0:0]'\n")
    result = json.loads(run(["/bin/sh", str(helper), "firewall-backend"], env=env))
    assert result["backend"] == "fw3"

    # Both active rule systems are reported instead of silently preferring one.
    command("fw4", "exit 0\n")
    command("nft", "[ \"$*\" = \"list table inet fw4\" ] && exit 0\nexit 1\n")
    result = json.loads(run(["/bin/sh", str(helper), "firewall-backend"], env=env))
    assert result["backend"] == "mixed"

    # Installed but unloaded firewall4 is distinguishable from active fw4.
    (bin_dir / "fw3").unlink()
    (bin_dir / "iptables-save").unlink()
    command("nft", "exit 1\n")
    result = json.loads(run(["/bin/sh", str(helper), "firewall-backend"], env=env))
    assert result["backend"] == "fw4-stopped"

def test_frontend_backend_contracts() -> None:
    app_js = (ROOT / "luci-app-nikki/htdocs/luci-static/resources/view/nikki/app.js").read_text()
    assert "s.description = _('After selecting an update source, be sure to click Save & Apply before checking for updates or updating the core!');" in app_js
    assert "s.description = E('span'" not in app_js
    proxy_js = (ROOT / "luci-app-nikki/htdocs/luci-static/resources/view/nikki/proxy.js").read_text()
    mixin_js = (ROOT / "luci-app-nikki/htdocs/luci-static/resources/view/nikki/mixin.js").read_text()
    tools_js = (ROOT / "luci-app-nikki/htdocs/luci-static/resources/tools/nikki.js").read_text()
    rpc_helper = (ROOT / "luci-app-nikki/root/usr/libexec/nikki-rpc").read_text()
    updater = (ROOT / "nikki/files/scripts/core_update.sh").read_text()
    init = (ROOT / "nikki/files/nikki.init").read_text()
    mixin = (ROOT / "nikki/files/scripts/mixin.sh").read_text()

    for source in ("official", "repository", "release", "direct"):
        assert f"o.value('{source}'" in app_js
        assert source in updater
    for preset in ("auto", "cloudflare", "jsdelivr", "github", "author_https", "author_http", "custom"):
        assert f"o.value('{preset}'" in app_js
        assert preset in updater
    for action in ("check", "update", "delete-current"):
        assert f"'{action}'" in app_js
        assert action in rpc_helper
        assert action in updater
    assert "rollback" not in app_js
    assert "delete-previous" not in app_js
    assert "mihomo.prev" not in app_js

    for helper_action in ("version", "profile", "update-subscription", "core-status", "core-action", "api", "identifiers", "firewall-backend", "debug", "write-file"):
        assert f"callNikki('{helper_action}'" in tools_js
        assert f"{helper_action})" in rpc_helper

    assert "dns_proxy_server_nameserver_policy" in mixin_js
    assert "dns_proxy_server_nameserver_policy" in mixin
    assert 'config_get_bool overwrite_dns_proxy_server_nameserver_policy' in init
    assert "del(.dns.proxy-server-nameserver-policy)" in init
    assert "range(1, 3600)" in proxy_js
    assert "range(1, 60)" in proxy_js
    assert "Current Firewall" in proxy_js
    assert "firewallBackend()" in proxy_js
    assert "o.value('redirect', _('REDIRECT'));" in proxy_js
    assert "ipv4_dns_mode" in proxy_js and "o.value('tproxy', _('TPROXY'));" in proxy_js

    status_start = app_js.index("form.TableSection, 'status'")
    status_end = app_js.index("form.NamedSection, 'config'", status_start)
    status_block = app_js[status_start:status_end]
    for label in ("App Version", "Core Version", "Core Status", "Reload Service", "Restart Service", "Update Dashboard", "Open Dashboard"):
        assert label in status_block
    for moved_label in ("Device Architecture", "Current Version", "Update Version", "Update Source", "Update Status", "Check Update", "Update Core", "Force Delete Current Core"):
        assert moved_label not in status_block

    core_start = app_js.index("form.NamedSection, 'core_update'")
    core_end = app_js.index("form.NamedSection, 'procd'", core_start)
    core_block = app_js[core_start:core_end]
    ordered_fields = ("'_device_architecture'", "'_current_version'", "'_update_version'", "'_update_source'", "'_update_status'", "'_check_update'", "'_update_core'", "'_delete_current_core'")
    positions = [core_block.index(field) for field in ordered_fields]
    assert positions == sorted(positions)
    for removed in ("User Agent", "Download Timeout", "Download Retry", "Minimum Free Space", "Save Changes", "Update File", "Update Address", "Saved Previous Version", "Rollback to Previous Version", "Delete Previous Version Now"):
        assert removed not in core_block
    assert "persistCoreUpdateConfig" not in app_js
    assert "Configuration changed" not in app_js
    assert "Configuration saved" not in app_js
    assert "ui.addNotification" not in app_js
    assert app_js.count("o.description = _(\'Be sure to click Save & Apply at the bottom right first!\');") == 2
    assert "font-size:14px" not in core_block
    assert "Confirm Core Deletion" in app_js
    assert "pollCoreOperation" in app_js
    assert "source_changed" in app_js
    assert "renderIntroNotice" not in app_js
    assert "insertBefore(notice" not in app_js
    assert "new form.Map('nikki', _('Nikki-X'), E('div'" in app_js

def test_static() -> None:
    assert not (ROOT / "nikki/files/ucode").exists()
    assert not (ROOT / "nikki/files/nftables").exists()
    assert (ROOT / "nikki/files/ipset/geoip6_cn.txt").exists()
    makefile = (ROOT / "nikki/Makefile").read_text()
    assert "+ip6tables" in makefile
    assert "+mihomo" not in makefile
    for dependency in ("+jshn", "+jsonfilter", "+ubus"):
        assert dependency in makefile
    assert "core_update.sh" in makefile
    updater_static = (ROOT / "nikki/files/scripts/core_update.sh").read_text()
    assert "tar -xOzf" in updater_static
    assert "tar -xzf" not in updater_static
    assert "+ip6tables-mod-nat" in makefile
    assert not (ROOT / "luci-app-nikki/root/usr/share/rpcd/ucode").exists()
    conf = (ROOT / "nikki/files/nikki.conf").read_text()

    # Keep LuCI defaults and the shipped UCI file aligned.
    for required_default in (
        "option 'scheduled_restart' '1'",
        "option 'scheduled_restart_cron' '0 3 * * *'",
        "option 'test_profile' '1'",
        "option 'log_level' 'warning'",
        "option 'mode' 'rule'",
        "option 'match_process' 'off'",
        "option 'tun_enabled' '1'",
        "option 'tun_device' 'nikki'",
        "option 'tun_stack' 'gvisor'",
        "option 'dns_enabled' '1'",
        "option 'dns_listen' '[::]:1053'",
        "option 'fake_ip_filter' '0'",
        "option 'hosts' '0'",
        "option 'dns_nameserver' '0'",
        "option 'dns_proxy_server_nameserver_policy' '0'",
        "option 'dns_nameserver_policy' '0'",
        "option 'sniffer_force_domain_name' '0'",
        "option 'sniffer_ignore_domain_name' '0'",
        "option 'sniffer_sniff' '0'",
        "option 'rule' '0'",
        "option 'rule_provider' '0'",
        "option 'mixin_file_content' '0'",
        "option 'ipv4_tcp_mode' 'redirect'",
        "option 'ipv4_udp_mode' 'tun'",
        "option 'ipv6_tcp_mode' 'redirect'",
        "option 'ipv6_udp_mode' 'tun'",
        "option 'ipv4_dns_mode' 'redirect'",
        "option 'ipv6_dns_mode' 'redirect'",
    ):
        assert required_default in conf

    for unmodified_default in (
        "option 'ipv6'",
        "option 'dns_cache_algorithm'",
        "option 'dns_ipv6'",
        "option 'dns_mode'",
        "option 'fake_ip_range'",
        "option 'fake_ip6_range'",
        "option 'fake_ip_ttl'",
        "option 'fake_ip_filter_mode'",
        "option 'fake_ip_cache'",
        "option 'dns_respect_rules'",
        "option 'dns_doh_prefer_http3'",
        "option 'dns_system_hosts'",
        "option 'dns_hosts'",
        "option 'dns_direct_nameserver_follow_policy'",
        "option 'sniffer'",
        "option 'sniffer_sniff_dns_mapping'",
        "option 'sniffer_sniff_pure_ip'",
    ):
        assert unmodified_default not in conf

    migrate_source = (ROOT / "nikki/files/uci-defaults/migrate.sh").read_text()
    assert "nikki.config.scheduled_restart=1" in migrate_source
    assert "nikki.config.scheduled_restart_cron='0 3 * * *'" in migrate_source
    assert "nikki.core_update.official_preset=auto" in migrate_source
    assert "nikki.core_update.repository_preset=custom" in migrate_source
    assert "nikki.core_update.repository_preset=auto" in migrate_source
    assert "nikki.mixin.dns_listen='[::]:1053'" in migrate_source
    assert "nikki.mixin.tun_enabled=1" in migrate_source
    assert "nikki.mixin.tun_stack=gvisor" in migrate_source
    assert "nikki.proxy.ipv4_tcp_mode=redirect" in migrate_source
    assert "nikki.proxy.ipv4_udp_mode=tun" in migrate_source
    assert "nikki.proxy.ipv6_tcp_mode=redirect" in migrate_source
    assert "nikki.proxy.ipv6_udp_mode=tun" in migrate_source
    assert "nikki.proxy.ipv6_dns_mode=redirect" in migrate_source

    updater_source = (ROOT / "nikki/files/scripts/core_update.sh").read_text()
    for official_source in (
        "https://gh-proxy.com/https://api.github.com/repos/",
        "https://gh-proxy.com/%s",
        "https://ghproxy.net/%s",
    ):
        assert official_source in updater_source
    assert 'API_TIMEOUT=10' in updater_source
    assert 'PROBE_TIMEOUT=5' in updater_source
    assert 'UPDATE_TASK_TIMEOUT=300' in updater_source
    assert 'timeout -s TERM "$UPDATE_TASK_TIMEOUT" "$0" update-worker' in updater_source
    assert 'validate_elf_architecture "$CORE_ACTIVE" "$EXPECTED_ARCH"' in updater_source
    assert 'rm -f "$CORE_ACTIVE"' in updater_source
    assert 'CORE_PREVIOUS' not in (ROOT / "nikki/files/scripts/include.sh").read_text()
    assert 'mihomo-linux-${arch}-${tag}.gz' in updater_source
    assert 'clash-linux-${arch}.tar.gz' in updater_source
    assert 'rollback_core' not in updater_source
    assert "auto) printf '%s\\n' proxy proxynet github" in updater_source
    for source in (
        "https://cdn.jsdelivr.net/gh/juewuy/ShellCrash@dev",
        "https://raw.githubusercontent.com/juewuy/ShellCrash/dev",
        "https://gh.jwsc.eu.org/dev",
        "https://testingcf.jsdelivr.net/gh/juewuy/ShellCrash@dev",
        "http://t.jwsc.eu.org",
    ):
        assert source in updater_source
    assert "official_preset" in conf
    assert "repository_preset" in conf
    core_conf = conf.split("config core_update 'core_update'", 1)[1].split("config subscription", 1)[0]
    for removed_option in ("user_agent", "timeout", "retry", "min_free_kb"):
        assert f"option '{removed_option}'" not in core_conf
    app_update_source = (ROOT / "luci-app-nikki/htdocs/luci-static/resources/view/nikki/app.js").read_text()
    assert "Automatic HTTPS Fallback" in app_update_source
    for label in (
        "PROXY Acceleration (Recommended)", "PROXYNET Acceleration", "GitHub Direct",
        "JSdelivr CF (Recommended)", "HTTPS Mirror", "HTTP Beta Source (Unsafe)",
    ):
        assert label in app_update_source
    for obsolete_label in (
        "Cloudflare jsDelivr (Recommended by ShellCrash)", "GitHub Raw",
        "Author HTTPS Mirror", "Author HTTP Beta Source (Unsafe)",
    ):
        assert obsolete_label not in app_update_source
    proxy_js = (ROOT / "luci-app-nikki/htdocs/luci-static/resources/view/nikki/proxy.js").read_text()
    for key in (
        "ipv4_tcp_mode", "ipv4_udp_mode", "ipv6_tcp_mode",
        "ipv6_udp_mode", "ipv4_dns_mode", "ipv6_dns_mode",
    ):
        assert key in conf
        assert key in proxy_js
    for old_key in (
        "tcp_mode", "udp_mode", "ipv4_proxy", "ipv6_proxy",
        "ipv4_dns_hijack", "ipv6_dns_hijack",
    ):
        assert f"option '{old_key}'" not in conf
    assert "TUN" in proxy_js
    assert "If you do not know what you are doing, do not change any settings on this page; keep the defaults." in proxy_js
    assert "m = new form.Map(" in proxy_js
    assert "_('Proxy Config'),\n            _('If you do not know what you are doing" in proxy_js
    assert "m.section(form.NamedSection, 'proxy', 'proxy');" in proxy_js
    assert "m.section(form.NamedSection, 'proxy', 'proxy', _('Proxy Config')" not in proxy_js
    assert proxy_js.count("Experimental feature; not recommended.") == 2
    init = (ROOT / "nikki/files/nikki.init").read_text()
    assert 'PROG="/usr/libexec/nikki/mihomo"' in init
    assert "update_core" in init
    assert "delete_current_core" in init
    assert "rollback_core" not in init
    assert "add_tun_policy_route" in init
    assert "remove_tun_policy_route" in init
    assert "tun_fw_mark" in init
    assert ".auto-route = false" in init
    assert ".auto-redirect = false" in init
    assert "PKG_VERSION:=2026.07.18-v6" in makefile
    assert "PKG_RELEASE:=7" in makefile
    luci_makefile = (ROOT / "luci-app-nikki/Makefile").read_text()
    assert "PKG_VERSION:=1.26.1-v6" in luci_makefile
    assert "PKG_RELEASE:=8" in luci_makefile
    assert "Hooks/Prepare/Post += Prepare/SetNikkiRpcExecutable" in luci_makefile
    assert "chmod 0755 $(PKG_BUILD_DIR)/root/usr/libexec/nikki-rpc" in luci_makefile
    permission_fallback = (
        ROOT / "luci-app-nikki/root/etc/uci-defaults/99_nikki_rpc_permissions"
    ).read_text()
    assert "chmod 0755 /usr/libexec/nikki-rpc" in permission_fallback

    app_js = (ROOT / "luci-app-nikki/htdocs/luci-static/resources/view/nikki/app.js").read_text()
    status_start = app_js.index("form.TableSection, 'status'")
    status_end = app_js.index("form.NamedSection, 'config'", status_start)
    status_block = app_js[status_start:status_end]
    for label in (
        "App Version", "Core Version", "Core Status", "Reload Service",
        "Restart Service", "Update Dashboard", "Open Dashboard",
    ):
        assert label in status_block
    for moved_label in (
        "Device Architecture", "Current Version", "Update Version",
        "Update Source", "Update Status", "Check Update", "Update Core",
        "Force Delete Current Core",
    ):
        assert moved_label not in status_block

    core_start = app_js.index("form.NamedSection, 'core_update'")
    core_end = app_js.index("form.NamedSection, 'procd'", core_start)
    core_block = app_js[core_start:core_end]
    ordered_fields = (
        "'_device_architecture'", "'_current_version'", "'_update_version'",
        "'_update_source'", "'_update_status'", "'_check_update'", "'_update_core'",
        "'_delete_current_core'",
    )
    positions = [core_block.index(field) for field in ordered_fields]
    assert positions == sorted(positions)
    assert "MetaCubeX Official Latest Version" in core_block
    assert "official_preset" in core_block
    assert "Official Download Source" in core_block
    assert "o.default = 'https://github.com/MetaCubeX/mihomo/releases';" in core_block
    for removed in (
        "User Agent", "Download Timeout", "Download Retry", "Minimum Free Space",
        "Save Changes", "Update File", "Update Address", "Saved Previous Version",
        "Rollback to Previous Version", "Delete Previous Version Now",
    ):
        assert removed not in core_block
    assert "persistCoreUpdateConfig" not in app_js
    assert "Configuration changed" not in app_js
    assert "Configuration saved" not in app_js
    assert "ui.addNotification" not in app_js
    assert app_js.count("o.description = _(\'Be sure to click Save & Apply at the bottom right first!\');") == 2
    assert "font-size:14px" not in core_block

    zh_hans = (ROOT / "luci-app-nikki/po/zh_Hans/nikki.po").read_text()
    for translated in (
        "本软件完全免费开源，安全且轻量",
        "防止DNS泄露",
        "选择更新源后，请务必先点击保存并应用",
        "已切换更新源，未检查更新！",
        "强行删除当前内核",
        "当前为固件内置核心，不占用可写空间，无法通过删除释放更新空间",
    ):
        assert translated in zh_hans

    test_frontend_backend_contracts()
    shell_files = list(ROOT.rglob("*.sh")) + list(ROOT.rglob("*.init"))
    for path in shell_files:
        run(["/bin/sh", "-n", str(path)])
        run(["busybox", "ash", "-n", str(path)])
    for path in (ROOT / "luci-app-nikki/htdocs").rglob("*.js"):
        run(["node", "--check", str(path)])
    for path in [
        ROOT / "luci-app-nikki/root/usr/share/rpcd/acl.d/luci-app-nikki.json",
        ROOT / "luci-app-nikki/root/usr/share/luci/menu.d/luci-app-nikki.json",
    ]:
        json.loads(path.read_text())


TEST_CASES = [
    "test_static",
    "test_mixin",
    "test_default_mixin_policy",
    "test_firewall",
    "test_default_firewall_modes",
    "test_ipv4_tcp_tproxy",
    "test_ipv6_tcp_redirect",
    "test_ipv4_dns_tproxy",
    "test_ipv6_dns_only",
    "test_ipv6_dns_redirect_only",
    "test_dns_tun_only",
    "test_firewall_apply",
    "test_tun_policy_routes",
    "test_core_space_policy",
    "test_firmware_core_symlink",
    "test_core_update",
    "test_official_source_channels",
    "test_shellcrash_repository_update",
    "test_shellcrash_automatic_https_fallback",
    "test_core_source_change_status",
    "test_core_archive_extraction",
    "test_rpc_transactional_write",
    "test_rpc_ipv6_wildcard",
    "test_rpc_firewall_backend_detection",
    "test_frontend_backend_contracts",
]

COMMON_MOCK_TESTS = {
    "test_mixin", "test_firewall", "test_default_firewall_modes",
    "test_ipv4_tcp_tproxy", "test_ipv6_tcp_redirect",
    "test_ipv4_dns_tproxy", "test_ipv6_dns_only",
    "test_ipv6_dns_redirect_only", "test_dns_tun_only",
    "test_firewall_apply",
}


def run_named_test(name: str) -> None:
    if name not in TEST_CASES:
        raise SystemExit(f"Unknown test: {name}")
    if name in {"test_static", "test_frontend_backend_contracts"}:
        globals()[name]()
        return
    with tempfile.TemporaryDirectory(prefix=f"nikki-{name}-") as td:
        tmp = Path(td)
        if name in COMMON_MOCK_TESTS:
            globals()[name](tmp, make_common_mocks(tmp))
        else:
            globals()[name](tmp)


def main() -> None:
    if len(sys.argv) == 2:
        run_named_test(sys.argv[1])
        print(f"PASS {sys.argv[1]}")
        return

    for name in TEST_CASES:
        print(f"Running {name}...", flush=True)
        try:
            subprocess.run(
                [sys.executable, str(Path(__file__).resolve()), name],
                check=True,
                timeout=90,
            )
        except subprocess.TimeoutExpired as exc:
            raise AssertionError(f"{name} exceeded 90 seconds") from exc
    print("All Nikki Legacy tests passed.")


if __name__ == "__main__":
    main()
