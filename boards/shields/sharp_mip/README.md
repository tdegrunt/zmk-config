# Sharp MIP Display

This shield provides a custom status screen for 160x68 Sharp
Memory-in-Pixel displays such as the nice!view.

This shield requires that an `&nice_view_spi` labeled SPI bus is provided with _at least_ MOSI, SCK, and CS pins defined.

## Disable custom widget

The shield includes a custom vertical widget. To use the built-in ZMK one, add
the following items to your `.conf` file:

```
CONFIG_ZMK_DISPLAY_STATUS_SCREEN_BUILT_IN=y
CONFIG_ZMK_LV_FONT_DEFAULT_SMALL_MONTSERRAT_26=y
CONFIG_LV_FONT_DEFAULT_MONTSERRAT_26=y
```

## Rotate screen

You can rotate the custom widget by 180 degrees. To do so, add the following item to your `.conf` file:

```
CONFIG_SHARP_MIP_ROTATE_180=y
```
