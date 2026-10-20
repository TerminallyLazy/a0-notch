"""No dependencies/processes. Lifecycle invalidates any old consumer lease."""
def install(**kwargs):
    from usr.plugins.a0_notch.helpers.relay import relay
    relay.reset()


def pre_update(**kwargs):
    install()


def uninstall(**kwargs):
    install()
