#!/usr/bin/env python3

import json
import os
import re
import shutil
import subprocess
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
  esac
done
case "$expr" in
  redir) echo 7891 ;;
  tproxy) echo 7892 ;;
  dns) echo '[::]:1053' ;;
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
        mixin.tun_enabled) _mock_value=0 ;;
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
        core.redirect_listener_name) _mock_value=redir-in ;;
        core.tproxy_listener_name) _mock_value=tproxy-in ;;
        proxy.enabled) _mock_value=1 ;;
        proxy.tcp_mode) _mock_value=redirect ;;
        proxy.udp_mode) _mock_value=tproxy ;;
        proxy.ipv4_proxy) _mock_value=1 ;;
        proxy.ipv4_dns_hijack) _mock_value=1 ;;
        proxy.ipv6_proxy) _mock_value=1 ;;
        proxy.ipv6_dns_hijack) _mock_value=1 ;;
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
        "NIK_MGL_OUT_MARK_V4",
        "NIK_NAT_PRE_DNS_V6",
        "NIK_NAT_PRE_TCP_V6",
        "NIK_NAT_OUT_DNS_V6",
        "NIK_NAT_OUT_TCP_V6",
        "NIK_MGL_PRE_CTRL_V6",
        "NIK_MGL_PRE_TPROXY_V6",
        "NIK_MGL_OUT_MARK_V6",
    ]
    for chain in expected:
        assert chain in rules
        assert len(chain) <= 28
    assert rules.count("-I PREROUTING 1 -j NIK_MGL_PRE_CTRL_V4") == 1
    assert rules.count("-I PREROUTING 1 -j NIK_MGL_PRE_CTRL_V6") == 1
    # iptables -I 1 reverses command order: emitting TCP before DNS leaves DNS first.
    assert rules.index("-I PREROUTING 1 -j NIK_NAT_PRE_TCP_V4") < rules.index("-I PREROUTING 1 -j NIK_NAT_PRE_DNS_V4")
    assert rules.index("-I OUTPUT 1 -j NIK_NAT_OUT_TCP_V4") < rules.index("-I OUTPUT 1 -j NIK_NAT_OUT_DNS_V4")
    assert "-j TPROXY --on-port 7892 --tproxy-mark 0x80/0xFF" in rules
    assert "-j REDIRECT --to-ports 7891" in rules
    assert "-j REDIRECT --to-ports 1053" in rules
    assert "--mac-source AA:BB:CC:DD:EE:FF" in rules
    assert "-s 192.0.2.10" in rules
    assert "-s 2001:db8::10" in rules
    # Family-specific selectors must not become wildcard rules in the other family.
    assert "NIK_NAT_PRE_TCP_V4 -i br-lan -s 2001:db8::10" not in rules
    assert "NIK_NAT_PRE_TCP_V6 -i br-lan -s 192.0.2.10" not in rules
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
    for name in ["iptables", "ip6tables"]:
        write(common["bin"] / name, xtables_mock)
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
    assert "NIK_MGL_PRE_TPROXY_V6" in rules6
    assert "family inet6" in sets
    assert "add nik_reserved_v6_t ::1/128 -exist" in sets
    assert "add nik_china_v6_t 2400:3200::/32 -exist" in sets
    assert "add nik_china_v4_t 1.0.1.0/24 -exist" in sets

def test_static() -> None:
    assert not (ROOT / ".github").exists()
    assert not (ROOT / "nikki/files/ucode").exists()
    assert not (ROOT / "nikki/files/nftables").exists()
    assert (ROOT / "nikki/files/ipset/geoip6_cn.txt").exists()
    makefile = (ROOT / "nikki/Makefile").read_text()
    assert "+ip6tables" in makefile
    assert "+ip6tables-mod-nat" in makefile
    assert not (ROOT / "luci-app-nikki/root/usr/share/rpcd/ucode").exists()
    shell_files = list(ROOT.rglob("*.sh")) + list(ROOT.rglob("*.init"))
    for path in shell_files:
        run(["/bin/sh", "-n", str(path)])
    for path in (ROOT / "luci-app-nikki/htdocs").rglob("*.js"):
        run(["node", "--check", str(path)])
    for path in [
        ROOT / "luci-app-nikki/root/usr/share/rpcd/acl.d/luci-app-nikki.json",
        ROOT / "luci-app-nikki/root/usr/share/luci/menu.d/luci-app-nikki.json",
    ]:
        json.loads(path.read_text())


def main() -> None:
    test_static()
    with tempfile.TemporaryDirectory(prefix="nikki-legacy-test-") as td:
        tmp = Path(td)
        common = make_common_mocks(tmp)
        test_mixin(tmp, common)
        test_firewall(tmp, common)
        test_firewall_apply(tmp, common)
    print("All Nikki Legacy tests passed.")


if __name__ == "__main__":
    main()
