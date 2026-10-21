"""No dependencies/processes. Lifecycle invalidates any old consumer lease."""
def install(**kwargs):
    from usr.plugins.a0_notch.helpers.relay import relay
    relay.reset()
    from usr.plugins.a0_notch.helpers.pagination import pages
    pages.clear()


def pre_update(**kwargs):
    install()


def uninstall(**kwargs):
    install()
