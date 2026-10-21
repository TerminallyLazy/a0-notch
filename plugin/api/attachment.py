from helpers.api import ApiHandler
from usr.plugins.a0_notch.helpers.attachments import handle


class NotchAttachment(ApiHandler):
    async def handle_request(self, request):
        # Parse bounded multipart ourselves; retain ApiHandler auth/CSRF wrappers.
        return await handle(request)

    async def process(self, input, request):
        return await self.handle_request(request)
