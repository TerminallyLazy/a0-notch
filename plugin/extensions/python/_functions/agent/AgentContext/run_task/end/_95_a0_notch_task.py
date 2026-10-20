from helpers.extension import Extension


class NotchTask(Extension):
    def execute(self, data=None, **kwargs):
        try:
            from usr.plugins.a0_notch.helpers.capture import task_started
            task_started(data or {})
        except Exception:
            pass
