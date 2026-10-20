from helpers.api import ApiHandler
from usr.plugins.a0_notch.helpers.http import handle


class NotchEvents(ApiHandler):
    async def handle_request(self, request):
        return await handle(request, status=False)

    async def process(self, input, request):
        return await self.handle_request(request)
