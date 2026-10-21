"""Narrow preset bridge tests; real upstream API, synthetic settings only."""
import asyncio
import threading
from types import SimpleNamespace as NS
from unittest.mock import Mock
import pytest
from usr.plugins.a0_notch.helpers import model_presets as mod, actions
from test_actions import targets
from usr.plugins.a0_notch.helpers.incarnation import token


@pytest.fixture
def models(targets, monkeypatch):
    from plugins._model_config.api import model_override as core
    context = targets[0][0]
    state = {}
    context.set_data = lambda key, value: state.__setitem__(key, value)
    context.get_data = lambda key: state.get(key)
    monkeypatch.setattr(mod.model_config, 'get_presets', lambda: [dict(name='Default', chat={'name':'safe-model', 'api_key':'NEVER_EXPORT', 'kwargs':{'token':'NEVER_EXPORT'}}), dict(name='SyntheticSecretABC', chat={'name':'SyntheticSecretABC-model'})])
    monkeypatch.setattr(mod.model_config, 'get_preset_by_name', lambda name: next((p for p in mod.model_config.get_presets() if p['name'] == name), None))
    monkeypatch.setattr(mod.model_config, 'is_chat_override_allowed', lambda agent: True)
    monkeypatch.setattr(mod.model_config, 'get_effective_preset_name', lambda agent: (state.get('chat_model_override') or {}).get('preset_name', 'Default'))
    monkeypatch.setattr(mod.model_config, 'get_configured_preset_name', lambda **kw: 'Default')
    monkeypatch.setattr(mod.model_config, 'get_embedding_model_config', lambda agent: {})
    monkeypatch.setattr(mod, 'get_secrets_manager', lambda c: NS(mask_values=lambda v, **kw: v.replace('SyntheticSecretABC', '[redacted]')))
    monkeypatch.setattr(core, 'save_tmp_chat', Mock())
    monkeypatch.setattr(core, '_notify_model_override_changed', Mock())
    monkeypatch.setattr(core.AgentContext, 'get', lambda id: next((c for c in targets[0] if c.id == id), None))
    return context, state, core


def request(context, **kw):
    return dict(context=context.id, incarnation=token(context), action='list') | kw


def test_list_and_real_core_set_clear(models):
    context, state, core = models
    result = asyncio.run(mod.dispatch(request(context)))
    assert result['presets'][1]['label'] == '[redacted]'
    assert 'NEVER_EXPORT' not in str(result) and 'SyntheticSecretABC' not in str(result)
    assert state == {}
    id = result['presets'][0]['id']
    asyncio.run(mod.dispatch(request(context, action='set', preset_id=id)))
    assert state == {'chat_model_override': {'preset_name': 'Default'}}
    core.save_tmp_chat.assert_called_once_with(context)
    asyncio.run(mod.dispatch(request(context, action='clear')))
    assert state == {'chat_model_override': None}


def test_replacement_during_preparation_never_sets(models, targets, monkeypatch):
    context, state, core = models
    original = mod.catalog
    def replacing(ctx):
        result = original(ctx)
        targets[0][0] = targets[1]('target')
        return result
    monkeypatch.setattr(mod, 'catalog', replacing)
    with pytest.raises(actions.TargetUnavailable):
        asyncio.run(mod.dispatch(request(context, action='set', preset_id=mod.preset_id('Default'))))
    assert state == {}; core.save_tmp_chat.assert_not_called()


def test_disabled_unknown_and_mask_failure_fail_closed(models, monkeypatch):
    context, state, core = models
    with pytest.raises(ValueError): asyncio.run(mod.dispatch(request(context, action='set', preset_id='x'*64)))
    monkeypatch.setattr(mod.model_config, 'is_chat_override_allowed', lambda agent: False)
    with pytest.raises(actions.TargetUnavailable): asyncio.run(mod.dispatch(request(context, action='clear')))
    monkeypatch.setattr(mod, 'get_secrets_manager', Mock(side_effect=RuntimeError('synthetic')))
    with pytest.raises(RuntimeError): asyncio.run(mod.dispatch(request(context)))
    assert state == {}; core.save_tmp_chat.assert_not_called()
