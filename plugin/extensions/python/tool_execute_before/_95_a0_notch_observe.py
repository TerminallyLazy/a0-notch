from helpers.extension import Extension


class NotchObserve(Extension):
    async def execute(self, tool_name='', tool_args=None, **kwargs):
        try:
            from usr.plugins.a0_notch.helpers.capture import observe
            observe(self.agent, 'tool_start', tool_name)
        except Exception:
            pass
        try:
            from usr.plugins.a0_notch.helpers.diffs import before
            await before(self.agent, tool_name, tool_args)
        except Exception:
            pass
