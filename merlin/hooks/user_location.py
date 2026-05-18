import logging
from datetime import datetime
from geopy.distance import geodesic  # type: ignore
from geopy.point import Point  # type: ignore
from merlin.hooks.base import BaseHook
from merlin.state import StateKey
from operator import itemgetter

logger = logging.getLogger(__name__)


class Hook(BaseHook):
    def __init__(self, state, mqtt_client, config):
        super().__init__(state, mqtt_client, config)

        self.mobile_device = {}
        self.vehicle = {}

        self.regions = [
            {
                "label": loc["label"],
                "location": Point(loc["latitude"], loc["longitude"]),
            }
            for loc in self.config.get("regions", [])
        ]

        self.threshold = self.config.get("threshold", 0.25)

        logger.info("hook 'user_location' loaded")

    def _filter_containing_regions(self, asset):
        containing_regions = []
        asset_location = asset["location"]

        for region in self.regions:
            dist = geodesic(asset_location, region["location"])
            if dist.miles > self.threshold:
                continue
            containing_regions.append(
                {"label": region["label"], "distance": dist.miles}
            )

        containing_regions.sort(key=itemgetter("distance"))
        return containing_regions

    async def on_state_change(self, key: str, old_value, new_value):
        if key == StateKey.DEV_VEHICLE_STATE:
            logger.info(f"vehicle update: {new_value}")

            self.vehicle["checkin"] = datetime.strptime(
                new_value["gps_time_utc"], "%Y%m%d%H%M%S"
            )
            self.vehicle["location"] = Point(
                new_value["latitude"], new_value["longitude"]
            )

        elif key == StateKey.DEV_MOBILE_STATE:
            logger.info(f"mobile device update: {new_value}")

            self.mobile_device["checkin"] = datetime.now()
            self.mobile_device["location"] = Point(
                new_value["gps_latitude"], new_value["gps_longitude"]
            )

        if not self.vehicle or not self.mobile_device:
            return

        mobile_device_regions = self._filter_containing_regions(self.mobile_device)
        vehicle_regions = self._filter_containing_regions(self.vehicle)

        # ~~~ different states ~~~
        #
        # m_loc = mobile_device_location
        # v_loc = vehicle_location
        # v_m_nearby = |m_loc - v_loc| < 0.25 mi
        # *_loc = A/B -> known location
        # *_loc = ? -> abroad
        # user_loc = user_location
        # v_safe = vehicle_is_safe
        #
        # m_loc | v_loc | v_m_nearby || user_loc | v_safe
        # ------|-------|------------||----------|-------
        #     A |     A |   assume Y ||        A |      Y
        #     A |     B |   assume N ||        A |      Y
        #     A |     ? |          Y ||        A |      Y
        #     A |     ? |          N ||        A |      N
        #     ? |     A |          Y ||        ? |      Y
        #     ? |     A |          N ||        ? |      Y
        #     ? |     ? |          Y ||        ? |      Y
        #     ? |     ? |          N ||        ? |      N

        # get the label of the region in which the mobile device
        # is most likely to be located
        m_loc = mobile_device_regions[0]["label"] if mobile_device_regions else None

        # get the label of the region in which the vehicle
        # is most likely to be located
        v_loc = vehicle_regions[0]["label"] if vehicle_regions else None

        # determine whether the mobile device and vehicle are
        # near each other; assume True if they are in the same
        # region; assume False if they are in different known
        # regions; go by distance if either are abroad (i.e.
        # in unspecified regions)
        v_m_nearby = (
            geodesic(self.mobile_device["location"], self.vehicle["location"]).miles
            <= self.threshold
            if m_loc is None or v_loc is None
            else m_loc == v_loc
        )

        # the vehicle should be considered potentially stole if
        # it is not in a known location AND it's not near the
        # phone; TODO note that this won't sound an alarm if
        # the vehicle is stolen while the mobile device is in
        # the vehicle at the time of theft
        v_safe = v_loc is not None or v_m_nearby

        # assume the user is with the mobile phone; TODO enhance
        # these heuristics at a later time through the use of
        # sensors in the house
        u_loc = m_loc

        u_home = "home" == u_loc.strip().casefold() if u_loc is not None else ""

        await self.state.set(StateKey.USR_LOC_HOME_FLAG, u_home)
        await self.state.set(StateKey.DEV_VEHICLE_SAFE_FLAG, v_safe)
