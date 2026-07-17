'use strict';
'require form';
'require view';
'require uci';
'require poll';
'require ui';
'require tools.nikki as nikki';

function renderStatus(running) {
    return updateStatus(E('input', { id: 'core_status', style: 'border: unset; font-style: italic; font-weight: bold;', readonly: '' }), running);
}

function updateStatus(element, running) {
    if (element) {
        element.style.color = running ? 'green' : 'red';
        element.value = running ? _('Running') : _('Not Running');
    }
    return element;
}

function textOrDash(value) {
    return value || '-';
}

function coreStatusText(info) {
    const labels = {
        idle: _('Not Checked'),
        checked: _('Checked'),
        updating: _('Updating'),
        success: _('Update Successful'),
        error: _('Update Failed'),
        rolled_back: _('Rolled Back'),
        previous_deleted: _('Previous Version Deleted')
    };
    let text = labels[info.status] || textOrDash(info.status);
    if (info.updated_at)
        text += ` · ${info.updated_at}`;
    if (info.error)
        text += ` · ${info.error}`;
    return text;
}

function runCoreAction(action, event, successMessage) {
    const button = event?.currentTarget;
    if (button)
        button.disabled = true;

    return nikki.coreAction(action).then(function (result) {
        if (!result?.success)
            throw new Error(result?.error_message || result?.error || _('Core operation failed'));
        ui.addNotification(null, E('p', {}, [successMessage]));
        window.setTimeout(function () { window.location.reload(); }, 250);
    }).catch(function (error) {
        if (button)
            button.disabled = false;
        ui.addNotification(null, E('p', {}, [error.message || String(error)]), 'danger');
    });
}

function actionButton(title, style, action, enabled, successMessage) {
    return E('button', {
        class: `cbi-button cbi-button-${style}`,
        disabled: enabled ? null : '',
        click: function (event) {
            event.preventDefault();
            return runCoreAction(action, event, successMessage);
        }
    }, [title]);
}

return view.extend({
    load: function () {
        return Promise.all([
            uci.load('nikki'),
            nikki.version(),
            nikki.coreStatus(),
            nikki.status(),
            nikki.listProfiles()
        ]);
    },
    render: function (data) {
        const subscriptions = uci.sections('nikki', 'subscription');
        const appVersion = data[1].app ?? '';
        const coreInfo = data[2] || {};
        const running = data[3];
        const profiles = data[4];
        const architecture = [coreInfo.architecture_uname, coreInfo.architecture_package].filter(Boolean).join(' / ');

        let m, s, o;

        m = new form.Map('nikki', _('Nikki'), `${_('Transparent Proxy with Mihomo on OpenWrt.')} <a href="https://github.com/nikkinikki-org/OpenWrt-nikki/wiki" target="_blank">${_('How To Use')}</a>`);

        s = m.section(form.TableSection, 'status', _('Status'));
        s.anonymous = true;

        o = s.option(form.Value, '_app_version', _('App Version'));
        o.readonly = true;
        o.load = function () { return appVersion; };
        o.write = function () { };

        o = s.option(form.Value, '_device_architecture', _('Device Architecture'));
        o.readonly = true;
        o.load = function () { return textOrDash(architecture); };
        o.write = function () { };

        o = s.option(form.Value, '_core_version', _('Current Running Version'));
        o.readonly = true;
        o.load = function () { return textOrDash(coreInfo.current_version); };
        o.write = function () { };

        o = s.option(form.DummyValue, '_previous_version', _('Previous Version'));
        o.cfgvalue = function () {
            return E('div', { style: 'display:flex;align-items:center;gap:.5rem;flex-wrap:wrap' }, [
                E('span', {}, [textOrDash(coreInfo.previous_version)]),
                actionButton(_('Rollback'), 'action', 'rollback', !!coreInfo.previous_version, _('Core rollback completed.')),
                actionButton(_('Delete'), 'negative', 'delete-previous', !!coreInfo.previous_version, _('Previous core deleted.'))
            ]);
        };

        o = s.option(form.Value, '_latest_version', _('Latest Version'));
        o.readonly = true;
        o.load = function () { return textOrDash(coreInfo.latest_version); };
        o.write = function () { };

        o = s.option(form.Value, '_update_source', _('Update Source'));
        o.readonly = true;
        o.load = function () { return textOrDash(coreInfo.source); };
        o.write = function () { };

        o = s.option(form.Value, '_resolved_asset', _('Resolved Asset'));
        o.readonly = true;
        o.load = function () { return textOrDash(coreInfo.resolved_asset); };
        o.write = function () { };

        o = s.option(form.Value, '_resolved_url', _('Resolved URL'));
        o.readonly = true;
        o.load = function () { return textOrDash(coreInfo.resolved_url); };
        o.write = function () { };

        o = s.option(form.Value, '_update_status', _('Update Status'));
        o.readonly = true;
        o.load = function () { return coreStatusText(coreInfo); };
        o.write = function () { };

        o = s.option(form.DummyValue, '_core_status', _('Core Status'));
        o.cfgvalue = function () { return renderStatus(running); };
        poll.add(function () {
            return L.resolveDefault(nikki.status()).then(function (isRunning) {
                updateStatus(document.getElementById('core_status'), isRunning);
            });
        });

        o = s.option(form.DummyValue, '_core_update_actions', _('Core Update'));
        o.cfgvalue = function () {
            return E('div', { style: 'display:flex;gap:.5rem;flex-wrap:wrap' }, [
                actionButton(_('Check Update'), 'action', 'check', true, _('Update source checked.')),
                actionButton(_('Update Core'), 'positive', 'update', true, _('Core updated successfully.'))
            ]);
        };

        o = s.option(form.Button, 'reload');
        o.inputstyle = 'action';
        o.inputtitle = _('Reload Service');
        o.onclick = function () { return nikki.reload(); };

        o = s.option(form.Button, 'restart');
        o.inputstyle = 'negative';
        o.inputtitle = _('Restart Service');
        o.onclick = function () { return nikki.restart(); };

        o = s.option(form.Button, 'update_dashboard');
        o.inputstyle = 'positive';
        o.inputtitle = _('Update Dashboard');
        o.onclick = function () { return nikki.updateDashboard(); };

        o = s.option(form.Button, 'open_dashboard');
        o.inputtitle = _('Open Dashboard');
        o.onclick = function () { return nikki.openDashboard(); };

        s = m.section(form.NamedSection, 'config', 'config', _('App Config'));

        o = s.option(form.Flag, 'enabled', _('Enable'));
        o.rmempty = false;

        o = s.option(form.ListValue, 'profile', _('Choose Profile'));
        o.optional = true;

        for (const profile of profiles)
            o.value('file:' + profile.name, _('File:') + profile.name);

        for (const subscription of subscriptions)
            o.value('subscription:' + subscription['.name'], _('Subscription:') + subscription.name);

        o = s.option(form.Value, 'start_delay', _('Start Delay'));
        o.datatype = 'uinteger';
        o.placeholder = _('Start Immidiately');

        o = s.option(form.Flag, 'scheduled_restart', _('Scheduled Restart'));
        o.rmempty = false;

        o = s.option(form.Value, 'scheduled_restart_cron', _('Scheduled Restart Cron'));
        o.retain = true;
        o.rmempty = false;
        o.depends('scheduled_restart', '1');

        o = s.option(form.Flag, 'test_profile', _('Test Profile'));
        o.rmempty = false;

        o = s.option(form.Flag, 'core_only', _('Core Only'));
        o.rmempty = false;

        s = m.section(form.NamedSection, 'core_update', 'core_update', _('Mihomo Core Update'));
        s.description = _('The active and previous cores are stored in two fixed slots. A downloaded core is validated before replacement; a failed restart restores both original slots.');

        o = s.option(form.ListValue, 'source_type', _('Source Type'));
        o.default = 'official';
        o.rmempty = false;
        o.value('official', _('Official MetaCubeX Releases'));
        o.value('repository', _('ShellCrash Sources'));
        o.value('release', _('Custom Releases URL'));
        o.value('direct', _('Exact Direct URL'));

        o = s.option(form.ListValue, 'repository_preset', _('ShellCrash Source'));
        o.default = 'auto';
        o.rmempty = false;
        o.depends('source_type', 'repository');
        o.value('auto', _('Automatic HTTPS Fallback (Recommended)'));
        o.value('cloudflare', _('Cloudflare jsDelivr (Recommended by ShellCrash)'));
        o.value('jsdelivr', _('jsDelivr CDN'));
        o.value('github', _('GitHub Raw'));
        o.value('author_https', _('Author HTTPS Mirror'));
        o.value('author_http', _('Author HTTP Beta Source (Unsafe)'));
        o.value('custom', _('Custom ShellCrash-Compatible Repository'));
        o.description = _('Automatic mode tries all four HTTPS sources and never falls back to the unencrypted HTTP beta source.');

        o = s.option(form.Value, 'repository_url', _('Custom Repository Base URL'));
        o.placeholder = 'https://example.com';
        o.depends({ source_type: 'repository', repository_preset: 'custom' });
        o.rmempty = false;

        o = s.option(form.Value, 'releases_url', _('Releases URL'));
        o.placeholder = 'https://example.com/releases';
        o.depends('source_type', 'release');
        o.rmempty = false;

        o = s.option(form.Value, 'releases_tag', _('Release Tag'));
        o.default = 'latest';
        o.placeholder = 'latest / v1.19.16';
        o.depends('source_type', 'release');
        o.rmempty = false;

        o = s.option(form.Value, 'direct_url', _('Exact Direct URL'));
        o.placeholder = 'https://example.com/mihomo-linux-aarch64_cortex-a53.tar.gz';
        o.depends('source_type', 'direct');
        o.rmempty = false;

        o = s.option(form.Value, 'user_agent', _('User Agent'));
        o.default = 'nikki-core-updater';
        o.rmempty = false;

        o = s.option(form.Value, 'timeout', _('Download Timeout'));
        o.datatype = 'range(1, 3600)';
        o.default = '120';
        o.rmempty = false;

        o = s.option(form.Value, 'retry', _('Download Retry'));
        o.datatype = 'uinteger';
        o.default = '2';
        o.rmempty = false;

        o = s.option(form.Value, 'min_free_kb', _('Minimum Free Space'));
        o.datatype = 'uinteger';
        o.default = '32768';
        o.rmempty = false;
        o.description = _('In KiB. Insufficient storage returns an error without replacing either core slot.');

        s = m.section(form.NamedSection, 'procd', 'procd', _('procd Config'));

        s.tab('general', _('General Config'));

        o = s.taboption('general', form.Flag, 'fast_reload', _('Fast Reload'));
        o.rmempty = false;

        s.tab('rlimit', _('RLIMIT Config'));

        o = s.taboption('rlimit', form.Value, 'rlimit_nproc_soft', _('Number of Processes Soft Limit'));
        o.datatype = 'uinteger';

        o = s.taboption('rlimit', form.Value, 'rlimit_nproc_hard', _('Number of Processes Hard Limit'));
        o.datatype = 'uinteger';

        o = s.taboption('rlimit', form.Value, 'rlimit_address_space_soft', _('Address Space Size Soft Limit'));
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('rlimit', form.Value, 'rlimit_address_space_hard', _('Address Space Size Hard Limit'));
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('rlimit', form.Value, 'rlimit_data_soft', _('Heap Size Soft Limit'));
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('rlimit', form.Value, 'rlimit_data_hard', _('Heap Size Hard Limit'));
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('rlimit', form.Value, 'rlimit_stack_soft', _('Stack Size Soft Limit'));
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('rlimit', form.Value, 'rlimit_stack_hard', _('Stack Size Hard Limit'));
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('rlimit', form.Value, 'rlimit_nofile_soft', _('Number of Open Files Soft Limit'));
        o.datatype = 'uinteger';

        o = s.taboption('rlimit', form.Value, 'rlimit_nofile_hard', _('Number of Open Files Hard Limit'));
        o.datatype = 'uinteger';

        s.tab('environment_variable', _('Environment Variable Config'));

        o = s.taboption('environment_variable', form.Value, 'env_go_max_procs', 'GOMAXPROCS');
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('environment_variable', form.Value, 'env_go_mem_limit', 'GOMEMLIMIT');
        o.datatype = 'uinteger';
        o.placeholder = _('Unlimited');

        o = s.taboption('environment_variable', form.DynamicList, 'env_safe_paths', _('Safe Paths'));
        o.load = function (section_id) {
            return this.super('load', section_id)?.split(':');
        };
        o.write = function (section_id, formvalue) {
            this.super('write', section_id, formvalue?.join(':'));
        };

        o = s.taboption('environment_variable', form.Flag, 'env_disable_loopback_detector', _('Disable Loopback Detector'));
        o.rmempty = false;

        o = s.taboption('environment_variable', form.Flag, 'env_disable_quic_go_gso', _('Disable GSO of quic-go'));
        o.rmempty = false;

        o = s.taboption('environment_variable', form.Flag, 'env_disable_quic_go_ecn', _('Disable ECN of quic-go'));
        o.rmempty = false;

        o = s.taboption('environment_variable', form.Flag, 'env_skip_system_ipv6_check', _('Skip System IPv6 Check'));
        o.rmempty = false;

        return m.render();
    }
});
