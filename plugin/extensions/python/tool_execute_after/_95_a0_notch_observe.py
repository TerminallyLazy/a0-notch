from helpers.extension import Extension


class NotchObserve(Extension):
    async def execute(self, tool_name='', response=None, **kwargs):
        metadata = None
        try:
            from usr.plugins.a0_notch.helpers.diffs import after
            metadata = await after(self.agent, tool_name, response)
        except Exception:
            pass
        try:
            from usr.plugins.a0_notch.helpers.capture import observe
            observe(self.agent, 'tool_end', tool_name, diff=metadata)
        except Exception:
            pass
