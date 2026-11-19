"""
Uses nwmurl to fetch operational forecast and analysis/assimilation data.

Usage: python fetch_nwm_data.py --start_date YYYYmmddHHMM --runinput [1,2,3,4,5,6,7,8,9,10,11]
       python fetch_nwm_data.py --start_date YYYYmmddHHMM --runinput 5 --chain_hours N

--chain_hours N (runinput 5 only): chained analysis-assimilation forcing for an N-hour run.
Takes the tm00 channel_rt file of every hourly AnA cycle from start + 1 h to start + N h and
writes chain_filelist.txt: "<url> <t-route file name>" per line. Like the forecast rename,
the file valid at V is named V - 1 h (t-route applies the file at T over [T, T + 1 h]).

These arguments are nwmurl arguments. The runinput is defined like this:
1: short-range forecast
2: medium-range forecast
3: medium-range forecast, no data assimilation
4: long-range forecast
5: analysis-assimilation
6: extended analysis-assimilation
7: extended analysis-assimilation, no data assimilation
8: long analysis-assimilation
9: long analysis-assimilation, no data assimilation
10: analysis-assimilation, no data assimilation
11: short-range forecast, no data assimilation
"""

import argparse
from datetime import datetime, timedelta
import nwmurl

def _parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--start_date",
        type= lambda s: (
            datetime.strptime(s, "%Y%m%d%H%M")
        ),
        help="The start date and time of the data to be collected, in YYYYmmddHHMM"
    )

    # A quick design note: as of the writing of this module, we will only use runinputs 1 and 5.
    # But I have included functionality to support all of the other run configurations, in the
    # spirit of the NRDS. The other AA runs may not be necessary though.
    # TODO: confirm design choice

    parser.add_argument(
        "--runinput",
        type=int,
        help="Represents NWM run configuration. See github.com/CIROH-UA/nwmurl for more details",
        choices=[1,2,3,4,5,6,7,8,9,10,11]
    )
    parser.add_argument(
        "--chain_hours",
        type=int,
        default=None,
        help="runinput 5 only: write chain_filelist.txt for an N-hour chained AnA run",
    )

    args = parser.parse_args()
    return args

def main():
    """
    Given the arguments start_date and runinput, build a nwmurl configuration and call nwmurl.

    Hardcoded assumptions:
    Only fetches one NWM run.
    Only fetches channel routing data.
    Only fetches CONUS data.
    Fetches data from Google Cloud Storage.
    Only fetches ensemble member 0 (only relevant for medium-range forecasts)
    """
    args = _parse_arguments()

    if args.chain_hours:
        write_ana_chain(args.start_date, args.chain_hours)
        return

    start_date = args.start_date.strftime("%Y%m%d%H%M")
    end_date = start_date # this only fetches one NWM run
    fcst_cycle = [args.start_date.hour]

    runinput = args.runinput

    if runinput in {1, 11}: # short-range forecast
        dt = 1
        num_hrs = 18
    elif runinput in {2, 3}: # medium-range forecast
        dt = 1
        num_hrs = 240
    elif runinput in {4}: # long-range forecast
        dt = 1
        num_hrs = 720
    elif runinput in {5, 10}: # analysis-assimilation
        dt = 0
        num_hrs = 1 # A design choice: These runs are 3 hours long, but we only really use them for
        # generating restarts. So we could get it to default to num_hrs = 1?
    elif runinput in {6, 7}: # extended analysis-assimilation
        dt = 0
        num_hrs = 28
    elif runinput in {8, 9}: # long-range analysis-assimilation
        dt = 0
        num_hrs = 12

    lead_time = [x+dt for x in range(num_hrs)]

    varinput = 1 # channel routing
    geoinput = 1 # CONUS
    urlbaseinput = 3 # GCS
    meminput = 1 if runinput == 2 else 0 # ensemble member; medium range is medium_range_mem1
    write_to_file = True

    nwmurl.generate_urls_operational(
        start_date,
        end_date,
        fcst_cycle,
        lead_time,
        varinput,
        geoinput,
        runinput,
        urlbaseinput,
        meminput,
        write_to_file
    )

def write_ana_chain(start: datetime, hours: int) -> None:
    """chain_filelist.txt: tm00 of AnA cycles start + 1 h .. start + hours, named for t-route."""
    if hours < 1:
        raise SystemExit("--chain_hours must be >= 1")
    first = start + timedelta(hours=1)
    last = start + timedelta(hours=hours)
    urls = nwmurl.generate_urls_operational(
        first.strftime("%Y%m%d0000"),
        last.strftime("%Y%m%d0000"),
        list(range(24)),  # every hourly cycle of each day; filtered below
        [0],              # tm00
        1,                # channel routing
        1,                # CONUS
        5,                # analysis-assimilation
        3,                # GCS
        0,
        False,
    )
    by_valid = {}
    for url in urls:
        # .../nwm.YYYYMMDD/analysis_assim/nwm.tHHz.analysis_assim.channel_rt.tm00.conus.nc
        day = url.split("/nwm.")[1][:8]
        hour = url.split("/nwm.t")[1][:2]
        valid = datetime.strptime(day + hour, "%Y%m%d%H")
        if first <= valid <= last:
            by_valid[valid] = url
    expected = [first + timedelta(hours=i) for i in range(hours)]
    missing = [v for v in expected if v not in by_valid]
    if missing:
        raise SystemExit(f"no AnA URL for {len(missing)} cycle(s), first {missing[0]}")
    with open("chain_filelist.txt", "wt") as f:
        for v in expected:
            name = (v - timedelta(hours=1)).strftime("%Y%m%d%H%M") + ".CHRTOUT_DOMAIN1"
            f.write(f"{by_valid[v]} {name}\n")
    print(f"chain_filelist.txt: {hours} AnA tm00 files, {first} .. {last}")


if __name__ == "__main__":
    main()
