'use strict';
'require form';
'require fs';
'require ui';
'require view';

let saveValidationFailed = false;

function isValidIPv4(value) {
	const parts = value.split('.');
	if (parts.length !== 4)
		return false;

	for (let i = 0; i < parts.length; i++) {
		const part = parts[i];
		if (!/^\d{1,3}$/.test(part))
			return false;
		if (part.length > 1 && part.charAt(0) === '0')
			return false;
		if (Number(part) > 255)
			return false;
	}
	return true;
}

function isValidIPv6(value) {
	let address = value;
	const zoneIndex = address.indexOf('%');
	if (zoneIndex >= 0) {
		if (!/^[0-9A-Za-z_.-]+$/.test(address.slice(zoneIndex + 1)))
			return false;
		address = address.slice(0, zoneIndex);
	}

	if (!address || address.indexOf(' ') >= 0 || address.indexOf(':::') >= 0)
		return false;

	const halves = address.split('::');
	if (halves.length > 2)
		return false;

	let groups = halves[0] ? halves[0].split(':') : [];
	if (halves.length === 2)
		groups = groups.concat(halves[1] ? halves[1].split(':') : []);

	let ipv4Groups = 0;
	if (groups.length > 0) {
		const last = groups[groups.length - 1];
		if (last.indexOf('.') >= 0) {
			if (!isValidIPv4(last))
				return false;
			groups = groups.slice(0, -1);
			ipv4Groups = 2;
		}
	}

	for (let i = 0; i < groups.length; i++) {
		if (!/^[0-9A-Fa-f]{1,4}$/.test(groups[i]))
			return false;
	}

	const total = groups.length + ipv4Groups;
	if (halves.length === 2)
		return total < 8;
	return total === 8;
}

function isValidIP(value) {
	return isValidIPv4(value) || isValidIPv6(value);
}

function isValidHostname(value) {
	let host = value;
	if (host.length > 253)
		return false;
	if (host.charAt(host.length - 1) === '.')
		host = host.slice(0, -1);
	if (!host)
		return false;

	const labels = host.split('.');
	for (let i = 0; i < labels.length; i++) {
		const label = labels[i];
		if (!label || label.length > 63)
			return false;
		if (!/^[A-Za-z0-9_*](?:[A-Za-z0-9_*-]*[A-Za-z0-9_*])?$/.test(label))
			return false;
	}
	return true;
}

function validateDomainRule(pattern, lineNo) {
	let value = pattern;

	if (value.indexOf('regexp:') === 0) {
		if (value.length <= 7)
			return _('Line %s: empty regexp pattern.').format(lineNo);
		return null;
	}

	if (value.indexOf('keyword:') === 0) {
		if (value.length <= 8)
			return _('Line %s: empty keyword pattern.').format(lineNo);
		return null;
	}

	if (value.indexOf('domain:') === 0)
		value = value.slice(7);
	else if (value.indexOf('full:') === 0)
		value = value.slice(5);

	if (!isValidHostname(value))
		return _('Line %s: invalid domain "%s".').format(lineNo, value);
	return null;
}

function validateRuleContent(type, content) {
	const lines = content.split('\n');
	for (let i = 0; i < lines.length; i++) {
		let line = lines[i];
		const commentIndex = line.indexOf('#');
		if (commentIndex >= 0)
			line = line.slice(0, commentIndex);
		line = line.trim();
		if (!line)
			continue;

		const lineNo = i + 1;
		if (type === 'hosts') {
			const fields = line.split(/\s+/);
			if (fields.length < 2)
				return _('Line %s: expected "<domain> <IP>".').format(lineNo);
			const domainError = validateDomainRule(fields[0], lineNo);
			if (domainError)
				return domainError;
			for (let j = 1; j < fields.length; j++) {
				if (!isValidIP(fields[j]))
					return _('Line %s: invalid IP address "%s".').format(lineNo, fields[j]);
			}
		} else if (type === 'redirect') {
			const fields = line.split(/\s+/);
			if (fields.length !== 2)
				return _('Line %s: expected "<domain> <target-domain>".').format(lineNo);
			const domainError = validateDomainRule(fields[0], lineNo);
			if (domainError)
				return domainError;
			if (!isValidHostname(fields[1]))
				return _('Line %s: invalid redirect target "%s".').format(lineNo, fields[1]);
		} else {
			const domainError = validateDomainRule(line, lineNo);
			if (domainError)
				return domainError;
		}
	}
	return null;
}

return view.extend({
	render() {
		const m = new form.Map('mosdns', _('Rule Settings'),
			_('The list of rules only apply to \'Default Config\' profiles.'));

		const s = m.section(form.TypedSection);
		s.anonymous = true;
		s.sortable = true;

		const handleSaveError = e => {
			ui.addNotification(null, E('p', _('Unable to save contents: %s').format(e.message)));
		};

		const rules = [
			{
				name: 'whitelist',
				title: _('White Lists'),
				file: '/etc/mosdns/rule/whitelist.txt',
				type: 'domain',
				desc: '<font color=\'red\'>'
					+ _('Added domain names always permit resolution using \'local DNS\' with the highest priority (one domain per line, supports domain matching rules).')
					+ '</font>'
			},
			{
				name: 'blocklist',
				title: _('Block Lists'),
				file: '/etc/mosdns/rule/blocklist.txt',
				type: 'domain',
				desc: '<font color=\'red\'>'
					+ _('Added domain names will block DNS resolution (one domain per line, supports domain matching rules).')
					+ '</font>'
			},
			{
				name: 'greylist',
				title: _('Grey Lists'),
				file: '/etc/mosdns/rule/greylist.txt',
				type: 'domain',
				desc: '<font color=\'red\'>'
					+ _('Added domain names will always use \'Remote DNS\' for resolution (one domain per line, supports domain matching rules).')
					+ '</font>'
			},
			{
				name: 'ddnslist',
				title: _('DDNS Lists'),
				file: '/etc/mosdns/rule/ddnslist.txt',
				type: 'domain',
				desc: '<font color=\'red\'>'
					+ _('Added domain names will always use \'Local DNS\' for resolution, with a forced TTL of 5 seconds, and results will not be cached (one domain per line, supports domain matching rules).')
					+ ' '
					+ _('When \'Custom DDNS DNS\' is enabled, the \'DDNS DNS server\' will be used instead.')
					+ '</font>'
			},
			{
				name: 'hostslist',
				title: _('Hosts'),
				file: '/etc/mosdns/rule/hosts.txt',
				type: 'hosts',
				desc: '<font color=\'red\'>'
					+ _('Custom Hosts rewrite, for example: baidu.com 10.0.0.1 (one rule per line, supports domain matching rules).')
					+ '</font>'
			},
			{
				name: 'redirectlist',
				title: _('Redirect'),
				file: '/etc/mosdns/rule/redirect.txt',
				type: 'redirect',
				desc: '<font color=\'red\'>'
					+ _('Redirecting requests for domain names. Request domain A, but return records for domain B, for example: baidu.com qq.com (one rule per line).')
					+ '</font>'
			},
			{
				name: 'localptrlist',
				title: _('Block PTR'),
				file: '/etc/mosdns/rule/local-ptr.txt',
				type: 'domain',
				desc: '<font color=\'red\'>'
					+ _('Added domain names will block PTR requests (one domain per line, supports domain matching rules).')
					+ '</font>'
			},
			{
				name: 'streamingmedialist',
				title: _('Streaming Media'),
				file: '/etc/mosdns/rule/streaming.txt',
				type: 'domain',
				desc: '<font color=\'red\'>'
					+ _('When enabling \'Custom Stream Media DNS\', added domains will always use the \'Streaming Media DNS server\' for resolution (one domain per line, supports domain matching rules).')
					+ '</font>'
			}
		];

		rules.forEach(rule => {
			s.tab(rule.name, rule.title);

			const o = s.taboption(rule.name, form.TextValue, '_' + rule.name, null, rule.desc);
			o.rows = 25;
			o.cfgvalue = () => fs.trimmed(rule.file).catch(() => '');
			o.write = function(section_id, formvalue) {
				return this.cfgvalue(section_id).then(value => {
					if (value === formvalue) {
						return;
					}
					const content = (formvalue && formvalue.trim()) ? formvalue.trim().replace(/\r\n/g, '\n') + '\n' : '';
					const error = validateRuleContent(rule.type, content);
					if (error) {
						saveValidationFailed = true;
						ui.addNotification(null, E('p', _('Invalid rule format, the file was not saved.') + ' ' + error), 'error');
						return Promise.reject(new Error(error));
					}
					return fs.write(rule.file, content).catch(handleSaveError);
				});
			};
			o.remove = () => fs.write(rule.file, '').catch(handleSaveError);
		});

		setTimeout(() => {
			rules.forEach(rule => {
				L.resolveDefault(fs.trimmed(rule.file), '').then(content => {
					const error = validateRuleContent(rule.type, content);
					if (error)
						ui.addNotification(null, E('p', _('Invalid rule format in %s: %s').format(rule.title, error)), 'warning');
				});
			});
		}, 300);

		return m.render();
	},

	handleSaveApply(ev) {
		return this.handleSave(ev).then(() => {
			if (saveValidationFailed) {
				saveValidationFailed = false;
				return;
			}
			window.location.reload();
		});
	},

	handleReset: null
});
