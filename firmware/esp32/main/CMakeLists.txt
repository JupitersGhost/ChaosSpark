idf_component_register(SRCS "main.c" "cf_core.c" "cf_pickup.c" "cf_pair.c" INCLUDE_DIRS "."
    PRIV_REQUIRES esp_adc esp_wifi esp_event esp_netif esp_timer esp_hw_support nvs_flash bt esp_driver_uart)
target_compile_options(${COMPONENT_LIB} PRIVATE -Wall -Wextra)
