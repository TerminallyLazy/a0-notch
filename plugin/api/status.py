from helpers.api import ApiHandler
from usr.plugins.a0_notch.helpers.http import handle


class NotchStatus(ApiHandler):
    async def handle_request(self, request):
        return await handle(request, status=True)

    async def process(self, input, request):
        return await self.handle_request(request)
