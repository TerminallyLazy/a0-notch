from helpers.api import ApiHandler
from usr.plugins.a0_notch.helpers.selected import handle


class NotchSelected(ApiHandler):
    async def handle_request(self, request):
        return await handle(request)

    async def process(self, input, request):
        return await self.handle_request(request)
