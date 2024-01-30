#!/usr/bin/env python3
import yaml
import json
import jinja2
import typing
import sys
import os.path
import functools
import shutil

class _Storage:
    def __init__(self):
        self.items = {}

    def set(self, f):
        '''Add (or replace) function into storage'''
        self.items[f.__name__] = f

    @property
    def dict(self) -> dict:
        return dict(self.items)

class _JinjaDecorator:
    '''Jinja decorator'''
    def __init__(self, func):
        self.func = func
        self._storage.set(self)

    @property
    def __name__(self) -> str:
        return self.func.__name__

    def __call__(self, *args, **kwargs):
        return self.func(*args, **kwargs)

class filter(_JinjaDecorator):
    '''Decorator to create filters'''
    _storage = _Storage()

    global extra_filters
    @staticmethod
    def extra_filters(__storage=_storage) -> dict:
        '''Overrides extra_filters'''
        return __storage.dict


class function(_JinjaDecorator):
    '''Decorator to create functions'''
    _storage = _Storage()

    global j2_environment
    @staticmethod
    def j2_environment(env, __storage=_storage):
        env.globals.update(**__storage.dict)
        return env

def j2_environment_params():
    '''Extra parameters for the Jinja2 environment'''
    return dict(
            trim_blocks=True,
            lstrip_blocks=True,
            line_statement_prefix='#~',
        )

@filter
def indent(s: str, width: typing.Union[int, str] = 4, first: bool = True, blank: bool = True) -> str:
    '''Replace default indent function with sane default values'''
    return jinja2.filters.do_indent(s=s, first=first, blank=blank)

@filter
def json_to_yaml(s: str) -> str:
    args = json.loads(s)
    return yaml.dump(args, sort_keys=False, default_flow_style=False)

@functools.cache
def build_and_template_dir():
    pos = None
    for i, j in enumerate(sys.argv[1:]):
        if j == '-o':
            pos = i + 1
            break
    if pos is None:
        return (None, None)
    build, template = sys.argv[1+pos], sys.argv[1+pos+1]
    return os.path.dirname(build), os.path.dirname(template)

@function
@functools.cache
def volume_ro(s: str, s2: str) -> str:
    build, template = build_and_template_dir()
    build, template = os.path.join(build, s), os.path.join(template, s)
    print(f'Copying {template} into {build}.')
    os.makedirs(os.path.dirname(build), exist_ok=True)
    shutil.copy2(src=template, dst=build)
    return f'- ./{template}:{s2}:ro'
