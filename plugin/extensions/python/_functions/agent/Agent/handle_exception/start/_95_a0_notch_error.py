from helpers.extension import Extension


class NotchError(Extension):
    async def execute(self, data=None, **kwargs):
        try:
            from usr.plugins.a0_notch.helpers.capture import exception
            exception(data or {})
        except Exception:
            pass
