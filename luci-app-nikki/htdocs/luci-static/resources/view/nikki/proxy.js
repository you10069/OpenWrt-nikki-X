'use strict';
'require form';
'require view';
'require uci';
'require network';
'require tools.widgets as widgets';
'require tools.nikki as nikki';

return view.extend({
    load: function () {
        return Promise.all([
            uci.load('nikki'),
            network.getHostHints(),
            network.getNetworks(),
            nikki.getIdentifiers(),
            L.resolveDefault(nikki.firewallBackend(), { backend: 'unknown' }),
        ]);
    },
    render: function (data) {
        const hosts = data[1].hosts;
        const networks = data[2];
        const users = data[3]?.users ?? [];
        const groups = data[3]?.groups ?? [];
        const firewallBackend = data[4]?.backend ?? 'unknown';
        const firewallLabels = {
            'fw3': _('firewall3 / iptables'),
            'fw4': _('firewall4 / nftables'),
            'mixed': _('Mixed state: firewall3 + firewall4'),
            'fw3-stopped': _('firewall3 / iptables (not running)'),
            'fw4-stopped': _('firewall4 / nftables (not running)'),
            'unknown': _('Unknown or firewall not running')
        };

        let m, s, o, so;

        m = new form.Map(
            'nikki',
            _('Proxy Config'),
            _('If you do not know what you are doing, do not change any settings on this page; keep the defaults.')
        );

        s = m.section(form.NamedSection, 'proxy', 'proxy');

        s.tab('proxy', _('Proxy Config'));

        o = s.taboption('proxy', form.Flag, 'enabled', _('Enable'));
        o.rmempty = false;

        o = s.taboption('proxy', form.DummyValue, '_firewall_backend', _('Current Firewall'));
        o.default = firewallLabels[firewallBackend] || firewallLabels.unknown;

        o = s.taboption('proxy', form.ListValue, 'ipv4_tcp_mode', _('IPv4 TCP Mode'));
        o.rmempty = false;
        o.value('disable', _('Disable'));
        o.value('redirect', _('REDIRECT'));
        o.value('tproxy', _('TPROXY'));
        o.value('tun', _('TUN'));

        o = s.taboption('proxy', form.ListValue, 'ipv4_udp_mode', _('IPv4 UDP Mode'));
        o.rmempty = false;
        o.value('disable', _('Disable'));
        o.value('tproxy', _('TPROXY'));
        o.value('tun', _('TUN'));

        o = s.taboption('proxy', form.ListValue, 'ipv6_tcp_mode', _('IPv6 TCP Mode'));
        o.rmempty = false;
        o.value('disable', _('Disable'));
        o.value('tproxy', _('TPROXY'));
        o.value('tun', _('TUN'));

        o = s.taboption('proxy', form.ListValue, 'ipv6_udp_mode', _('IPv6 UDP Mode'));
        o.rmempty = false;
        o.value('disable', _('Disable'));
        o.value('tproxy', _('TPROXY'));
        o.value('tun', _('TUN'));

        o = s.taboption('proxy', form.ListValue, 'ipv4_dns_mode', _('IPv4 DNS Mode'), _('REDIRECT TCP/UDP port 53 to the Mihomo DNS listener, or route it through TUN while preserving the original destination.'));
        o.rmempty = false;
        o.value('disable', _('Disable'));
        o.value('redirect', _('REDIRECT to Mihomo DNS'));
        o.value('tun', _('TUN'));

        o = s.taboption('proxy', form.ListValue, 'ipv6_dns_mode', _('IPv6 DNS Mode'), _('TPROXY TCP/UDP port 53 to the Mihomo TPROXY listener, or route it through TUN; neither mode enters the built-in DNS listener.'));
        o.rmempty = false;
        o.value('disable', _('Disable'));
        o.value('tproxy', _('TPROXY'));
        o.value('tun', _('TUN'));

        o = s.taboption('proxy', form.Value, 'tun_timeout', _('TUN Device Timeout'));
        o.datatype = 'range(1, 3600)';
        o.default = '30';
        o.depends('ipv4_tcp_mode', 'tun');
        o.depends('ipv4_udp_mode', 'tun');
        o.depends('ipv6_tcp_mode', 'tun');
        o.depends('ipv6_udp_mode', 'tun');
        o.depends('ipv4_dns_mode', 'tun');
        o.depends('ipv6_dns_mode', 'tun');

        o = s.taboption('proxy', form.Value, 'tun_interval', _('TUN Device Check Interval'));
        o.datatype = 'range(1, 60)';
        o.default = '1';
        o.depends('ipv4_tcp_mode', 'tun');
        o.depends('ipv4_udp_mode', 'tun');
        o.depends('ipv6_tcp_mode', 'tun');
        o.depends('ipv6_udp_mode', 'tun');
        o.depends('ipv4_dns_mode', 'tun');
        o.depends('ipv6_dns_mode', 'tun');

        s.tab('router', _('Router Proxy'));

        o = s.taboption('router', form.Flag, 'router_proxy', _('Enable'));
        o.rmempty = false;

        o = s.taboption('router', form.SectionValue, '_router_access_control', form.TableSection, 'router_access_control', _('Access Control'));
        o.retain = true;
        o.depends('router_proxy', '1');

        o.subsection.addremove = true;
        o.subsection.anonymous = true;
        o.subsection.sortable = true;

        so = o.subsection.option(form.Flag, 'enabled', _('Enable'));
        so.default = '1';
        so.rmempty = false;

        so = o.subsection.option(form.DynamicList, 'user', _('User'));

        for (const user of users) {
            so.value(user);
        };

        so = o.subsection.option(form.DynamicList, 'group', _('Group'));

        for (const group of groups) {
            so.value(group);
        };

        so = o.subsection.option(form.Flag, 'dns', _('DNS'));
        so.rmempty = false;

        so = o.subsection.option(form.Flag, 'proxy', _('Proxy'));
        so.rmempty = false;

        s.tab('lan', _('LAN Proxy'));

        o = s.taboption('lan', form.Flag, 'lan_proxy', _('Enable'));
        o.rmempty = false;

        o = s.taboption('lan', form.DynamicList, 'lan_inbound_interface', _('Inbound Interface'));
        o.retain = true;
        o.rmempty = false;
        o.depends('lan_proxy', '1');

        for (const network of networks) {
            if (network.getName() === 'loopback') {
                continue;
            }
            o.value(network.getName());
        }

        o = s.taboption('lan', form.SectionValue, '_lan_access_control', form.TableSection, 'lan_access_control', _('Access Control'));
        o.retain = true;
        o.depends('lan_proxy', '1');

        o.subsection.addremove = true;
        o.subsection.anonymous = true;
        o.subsection.sortable = true;

        so = o.subsection.option(form.Flag, 'enabled', _('Enable'));
        so.default = '1';
        so.rmempty = false;

        so = o.subsection.option(form.DynamicList, 'ip', 'IP');
        so.datatype = 'ip4addr';

        for (const mac in hosts) {
            const host = hosts[mac];
            for (const ip of host.ipaddrs) {
                const hint = host.name ?? mac;
                so.value(ip, hint ? '%s (%s)'.format(ip, hint) : ip);
            };
        };

        so = o.subsection.option(form.DynamicList, 'ip6', 'IP6');
        so.datatype = 'ip6addr';

        for (const mac in hosts) {
            const host = hosts[mac];
            for (const ip of (host.ip6addrs ?? [])) {
                const hint = host.name ?? mac;
                so.value(ip, hint ? '%s (%s)'.format(ip, hint) : ip);
            };
        };

        so = o.subsection.option(form.DynamicList, 'mac', 'MAC');
        so.datatype = 'macaddr';

        for (const mac in hosts) {
            const host = hosts[mac];
            const hint = host.name ?? host.ipaddrs[0];
            so.value(mac, hint ? '%s (%s)'.format(mac, hint) : mac);
        };

        so = o.subsection.option(form.Flag, 'dns', _('DNS'));
        so.rmempty = false;

        so = o.subsection.option(form.Flag, 'proxy', _('Proxy'));
        so.rmempty = false;

        s.tab('bypass', _('Bypass'));

        o = s.taboption('bypass', form.Flag, 'bypass_china_mainland_ip', _('Bypass China Mainland IP'), _('Experimental feature; not recommended.'));
        o.rmempty = false;

        o = s.taboption('bypass', form.Flag, 'bypass_china_mainland_ip6', _('Bypass China Mainland IP6'), _('Experimental feature; not recommended.'));
        o.rmempty = false;

        o = s.taboption('bypass', form.Value, 'proxy_tcp_dport', _('Destination TCP Port to Proxy'));
        o.rmempty = false;
        o.value('0-65535', _('All Port'));
        o.value('21 22 80 110 143 194 443 465 853 993 995 8080 8443', _('Commonly Used Port'));

        o = s.taboption('bypass', form.Value, 'proxy_udp_dport', _('Destination UDP Port to Proxy'));
        o.rmempty = false;
        o.value('0-65535', _('All Port'));
        o.value('123 443 8443', _('Commonly Used Port'));

        o = s.taboption('bypass', form.DynamicList, 'bypass_dscp', _('Bypass DSCP'));
        o.datatype = 'range(0, 63)';

        o = s.taboption('bypass', form.DynamicList, 'bypass_fwmark', _('Bypass FWMark'));

        s.tab('misc', _('Misc'));

        o = s.taboption('misc', form.DynamicList, 'reserved_ip', _('Reserved IP'));
        o.datatype = 'ip4addr';

        o = s.taboption('misc', form.DynamicList, 'reserved_ip6', _('Reserved IP6'));
        o.datatype = 'ip6addr';

        return m.render();
    }
});
