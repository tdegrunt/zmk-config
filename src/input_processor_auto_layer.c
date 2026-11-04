/*
 * SPDX-License-Identifier: MIT
 *
 * Auto layer input processor: turns a layer on while a pointing device moves.
 *
 * Works like ZMK's temp layer input processor (zmk,input-processor-temp-layer),
 * with the same parameters and properties, but keeps its state per instance.
 * The stock one handles its layer changes through instance 0 only, so two
 * instances turning on two layers interfere with each other.
 *
 *   param1: the layer to turn on
 *   param2: turn it off again after this many ms without input (0: never)
 *
 * The layer also turns off when a key outside excluded-positions is pressed.
 * Input within require-prior-idle-ms of a keystroke doesn't turn it on.
 */

#define DT_DRV_COMPAT zmk_input_processor_auto_layer

#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/sys/atomic.h>
#include <drivers/input_processor.h>
#include <zephyr/logging/log.h>
#include <zmk/keymap.h>
#include <zmk/event_manager.h>
#include <zmk/events/position_state_changed.h>
#include <zmk/events/keycode_state_changed.h>
#include <zmk/events/layer_state_changed.h>

LOG_MODULE_DECLARE(zmk, CONFIG_ZMK_LOG_LEVEL);

struct auto_layer_config {
    int32_t require_prior_idle_ms;
    const uint16_t *excluded_positions;
    size_t num_positions;
};

struct auto_layer_data {
    const struct device *dev;
    // Layer changes run on the system work queue, like the keymap's own.
    struct k_work activate_work;
    struct k_work_delayable deactivate_work;
    atomic_t layer;
    atomic_t active;
    int64_t last_keycode_ms;
};

static bool position_is_excluded(const struct auto_layer_config *cfg, uint32_t position) {
    for (size_t i = 0; i < cfg->num_positions; i++) {
        if (cfg->excluded_positions[i] == position) {
            return true;
        }
    }
    return false;
}

static void deactivate(struct auto_layer_data *data) {
    if (atomic_cas(&data->active, 1, 0)) {
        zmk_keymap_layer_deactivate((zmk_keymap_layer_id_t)atomic_get(&data->layer), false);
    }
}

static void activate_work_cb(struct k_work *work) {
    struct auto_layer_data *data = CONTAINER_OF(work, struct auto_layer_data, activate_work);
    if (atomic_cas(&data->active, 0, 1)) {
        zmk_keymap_layer_activate((zmk_keymap_layer_id_t)atomic_get(&data->layer), false);
    }
}

static void deactivate_work_cb(struct k_work *work) {
    struct k_work_delayable *dwork = k_work_delayable_from_work(work);
    struct auto_layer_data *data = CONTAINER_OF(dwork, struct auto_layer_data, deactivate_work);
    deactivate(data);
}

static int auto_layer_handle_event(const struct device *dev, struct input_event *event,
                                   uint32_t param1, uint32_t param2,
                                   struct zmk_input_processor_state *state) {
    const struct auto_layer_config *cfg = dev->config;
    struct auto_layer_data *data = dev->data;

    if (param1 >= ZMK_KEYMAP_LAYERS_LEN) {
        LOG_ERR("Invalid layer: %d", param1);
        return -EINVAL;
    }

    if (!atomic_get(&data->active)) {
        if (k_uptime_get() < data->last_keycode_ms + cfg->require_prior_idle_ms) {
            return ZMK_INPUT_PROC_CONTINUE;
        }
        atomic_set(&data->layer, param1);
        k_work_submit(&data->activate_work);
    }

    if (param2 > 0) {
        k_work_reschedule(&data->deactivate_work, K_MSEC(param2));
    }

    return ZMK_INPUT_PROC_CONTINUE;
}

static void handle_event_for(const struct device *dev, const zmk_event_t *eh) {
    const struct auto_layer_config *cfg = dev->config;
    struct auto_layer_data *data = dev->data;

    const struct zmk_position_state_changed *pos = as_zmk_position_state_changed(eh);
    if (pos) {
        if (pos->state && !position_is_excluded(cfg, pos->position)) {
            k_work_cancel_delayable(&data->deactivate_work);
            deactivate(data);
        }
        return;
    }

    const struct zmk_keycode_state_changed *kc = as_zmk_keycode_state_changed(eh);
    if (kc) {
        if (kc->state) {
            data->last_keycode_ms = kc->timestamp;
        }
        return;
    }

    // Something else turned the layer off (e.g. &to): forget it was on.
    if (as_zmk_layer_state_changed(eh) && atomic_get(&data->active) &&
        !zmk_keymap_layer_active((zmk_keymap_layer_id_t)atomic_get(&data->layer))) {
        atomic_set(&data->active, 0);
        k_work_cancel_delayable(&data->deactivate_work);
    }
}

#define HANDLE_EVENT_FOR(n) handle_event_for(DEVICE_DT_INST_GET(n), eh);

static int auto_layer_listener(const zmk_event_t *eh) {
    DT_INST_FOREACH_STATUS_OKAY(HANDLE_EVENT_FOR)
    return ZMK_EV_EVENT_BUBBLE;
}

ZMK_LISTENER(processor_auto_layer, auto_layer_listener);
ZMK_SUBSCRIPTION(processor_auto_layer, zmk_position_state_changed);
ZMK_SUBSCRIPTION(processor_auto_layer, zmk_keycode_state_changed);
ZMK_SUBSCRIPTION(processor_auto_layer, zmk_layer_state_changed);

static int auto_layer_init(const struct device *dev) {
    struct auto_layer_data *data = dev->data;
    data->dev = dev;
    k_work_init(&data->activate_work, activate_work_cb);
    k_work_init_delayable(&data->deactivate_work, deactivate_work_cb);
    return 0;
}

static const struct zmk_input_processor_driver_api auto_layer_driver_api = {
    .handle_event = auto_layer_handle_event,
};

#define AUTO_LAYER_INST(n)                                                                         \
    static const uint16_t auto_layer_excluded_##n[] = DT_INST_PROP(n, excluded_positions);       \
    static const struct auto_layer_config auto_layer_config_##n = {                                \
        .require_prior_idle_ms = DT_INST_PROP_OR(n, require_prior_idle_ms, 0),                     \
        .excluded_positions = auto_layer_excluded_##n,                                             \
        .num_positions = DT_INST_PROP_LEN(n, excluded_positions),                                  \
    };                                                                                             \
    static struct auto_layer_data auto_layer_data_##n = {};                                        \
    DEVICE_DT_INST_DEFINE(n, auto_layer_init, NULL, &auto_layer_data_##n,                          \
                          &auto_layer_config_##n, POST_KERNEL,                                     \
                          CONFIG_KERNEL_INIT_PRIORITY_DEFAULT, &auto_layer_driver_api);

DT_INST_FOREACH_STATUS_OKAY(AUTO_LAYER_INST)
