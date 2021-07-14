load("@build_bazel_rules_apple//apple:ios.bzl", rules_apple_ios_application = "ios_application")
load("//rules:library.bzl", "apple_library")
load("//rules:framework.bzl", "apple_framework")
load("//rules:plists.bzl", "info_plists_by_setting")

_IOS_APPLICATION_KWARGS = [
    "bundle_id",
    "infoplists",
    "env",
    "minimum_os_version",
    "test_host",
    "families",
    "entitlements",
    "entitlements_validation",
    "extensions",
    "visibility",
    "launch_storyboard",
    "provisioning_profile",
    "resources",
    "app_icons",
    "tags",
    "strings",
    "alternate_icons",
    "settings_bundle",
    "minimum_deployment_os_version"
]

def ios_application(name, apple_library = apple_library, apple_framework = apple_framework, use_apple_framework = False, infoplists_by_build_setting = {}, **kwargs):
    """
    Builds and packages an iOS application.

    Args:
        name: The name of the iOS application.
        apple_library: The macro used to package sources into a library.
        infoplists_by_build_setting: A dictionary of infoplists grouped by bazel build setting.

                                     Each value is applied if the respective bazel build setting
                                     is resolved during the analysis phase.

                                     If '//conditions:default' is not set the value in 'infoplists'
                                     is set as default.
        **kwargs: Arguments passed to the apple_library and ios_application rules as appropriate.
    """

    application_kwargs = {arg: kwargs.pop(arg) for arg in _IOS_APPLICATION_KWARGS if arg in kwargs}

    if use_apple_framework:
        fw_name = name + "_app_framework"
        apple_framework(name = fw_name, apple_library = apple_library, platforms = {"ios": application_kwargs.get("minimum_os_version")}, **kwargs)
        deps = [fw_name]
        launch_screen_storyboard_name = fw_name + "_launch_screen_storyboard"
    else:
        library = apple_library(name = name, namespace_is_module_name = False, platforms = {"ios": application_kwargs.get("minimum_os_version")}, **kwargs)
        deps = library.lib_names
        launch_screen_storyboard_name = library.launch_screen_storyboard_name

    application_kwargs["launch_storyboard"] = application_kwargs.pop("launch_storyboard", launch_screen_storyboard_name)
    application_kwargs["families"] = application_kwargs.pop("families", ["iphone", "ipad"])

    rules_apple_ios_application(
        name = name,
        deps = deps,
        infoplists = info_plists_by_setting(name = name, infoplists_by_build_setting = infoplists_by_build_setting, default_infoplists = application_kwargs.pop("infoplists", [])),
        **application_kwargs
    )
