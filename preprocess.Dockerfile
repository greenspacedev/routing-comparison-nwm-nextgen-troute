FROM amazonlinux:2023 AS builder
ENV START_TIME=""
ENV FORECAST_TYPE=""

RUN dnf install -y git && dnf clean all

# troute-usgsdf source. Defaults to greenspacedev's fork; override with
#   --build-arg USGSDF_REPO=... --build-arg USGSDF_BRANCH=...
# USGSDF_COMMIT pins an exact commit, and changing it forces Docker to re-clone
# instead of reusing a cached clone of an older commit on the same branch.
# Leave it empty to take the branch tip.
ARG USGSDF_REPO=https://github.com/greenspacedev/troute-usgsdf.git
ARG USGSDF_BRANCH=vectorize-routelink-gages
ARG USGSDF_COMMIT=
RUN git clone -b "${USGSDF_BRANCH}" "${USGSDF_REPO}" /opt/troute-da \
    && if [ -n "${USGSDF_COMMIT}" ]; then git -C /opt/troute-da checkout -q "${USGSDF_COMMIT}"; fi \
    && echo "troute-usgsdf: ${USGSDF_REPO} ${USGSDF_BRANCH} @ $(git -C /opt/troute-da rev-parse --short HEAD)"


RUN dnf -y install \
        python3.11 tar gzip\
    && dnf clean all \
    && rm -rf /var/cache/dnf

RUN curl -LsSf https://astral.sh/uv/0.6.12/install.sh | sh
ENV PATH="/root/.local/bin:${PATH}"

RUN ln -sf /usr/bin/python3.11 /usr/bin/python3 \
    && ln -sf /usr/bin/python3.11 /usr/bin/python

COPY .. /routing-comparison-nwm-nextgen-troute

WORKDIR /routing-comparison-nwm-nextgen-troute
RUN uv pip install --system -e . \
    && rm -rf /root/.cache/uv /root/.cache/pip


WORKDIR /opt/troute-da
RUN uv pip install --system -e . \
    && rm -rf /root/.cache/uv /root/.cache/pip


FROM amazonlinux:2023 AS runtime


RUN dnf -y install \
        python3.11 wget gettext \
    && dnf clean all \
    && rm -rf /var/cache/dnf

RUN ln -sf /usr/bin/python3.11 /usr/bin/python3 \
    && ln -sf /usr/bin/python3.11 /usr/bin/python

COPY --from=builder /opt/troute-da /opt/troute-da

COPY --from=builder /usr/local/lib/python3.11/site-packages   \
    /usr/local/lib/python3.11/site-packages
COPY --from=builder /usr/local/lib64/python3.11/site-packages \
    /usr/local/lib64/python3.11/site-packages
COPY --from=builder /usr/local/bin                            /usr/local/bin
COPY --from=builder /routing-comparison-nwm-nextgen-troute/data    \
    /routing-comparison-nwm-nextgen-troute/data
COPY --from=builder /routing-comparison-nwm-nextgen-troute/scripts    \
    /routing-comparison-nwm-nextgen-troute/scripts

WORKDIR /routing-comparison-nwm-nextgen-troute
RUN wget \
    https://ciroh-community-ngen-datastream.s3.amazonaws.com/resources/v2.2_hydrofabric/troute_restart/RouteLink_CONUS.nc
RUN mv RouteLink_CONUS.nc /routing-comparison-nwm-nextgen-troute/data

ENTRYPOINT bash scripts/bash/preprocess_data.sh --START_TIME ${START_TIME} \
    --FORECAST_TYPE ${FORECAST_TYPE} --VPU ${VPU} --N_CPUS ${N_CPUS}