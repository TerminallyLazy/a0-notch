from helpers.extension import Extension


class NotchObserve(Extension):
    async def execute(self, tool_name='', **kwargs):
        try:
            from usr.plugins.a0_notch.helpers.capture import observe
            observe(self.agent, 'tool_start', tool_name)
        except Exception:
            pass
