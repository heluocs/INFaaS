# Generated by the protocol buffer compiler.  DO NOT EDIT!
# source: infaas_request_status.proto

import sys
_b=sys.version_info[0]<3 and (lambda x:x) or (lambda x:x.encode('latin1'))
from google.protobuf.internal import enum_type_wrapper
from google.protobuf import descriptor as _descriptor
from google.protobuf import message as _message
from google.protobuf import reflection as _reflection
from google.protobuf import symbol_database as _symbol_database
# @@protoc_insertion_point(imports)

_sym_db = _symbol_database.Default()




DESCRIPTOR = _descriptor.FileDescriptor(
  name='infaas_request_status.proto',
  package='infaas.internal',
  syntax='proto3',
  serialized_options=None,
  serialized_pb=_b('\n\x1binfaas_request_status.proto\x12\x0finfaas.internal\"\\\n\x13InfaasRequestStatus\x12\x38\n\x06status\x18\x01 \x01(\x0e\x32(.infaas.internal.InfaasRequestStatusEnum\x12\x0b\n\x03msg\x18\x02 \x01(\t*D\n\x17InfaasRequestStatusEnum\x12\x0b\n\x07INVALID\x10\x00\x12\x0b\n\x07SUCCESS\x10\x01\x12\x0f\n\x0bUNAVAILABLE\x10\x02\x62\x06proto3')
)

_INFAASREQUESTSTATUSENUM = _descriptor.EnumDescriptor(
  name='InfaasRequestStatusEnum',
  full_name='infaas.internal.InfaasRequestStatusEnum',
  filename=None,
  file=DESCRIPTOR,
  values=[
    _descriptor.EnumValueDescriptor(
      name='INVALID', index=0, number=0,
      serialized_options=None,
      type=None),
    _descriptor.EnumValueDescriptor(
      name='SUCCESS', index=1, number=1,
      serialized_options=None,
      type=None),
    _descriptor.EnumValueDescriptor(
      name='UNAVAILABLE', index=2, number=2,
      serialized_options=None,
      type=None),
  ],
  containing_type=None,
  serialized_options=None,
  serialized_start=142,
  serialized_end=210,
)
_sym_db.RegisterEnumDescriptor(_INFAASREQUESTSTATUSENUM)

InfaasRequestStatusEnum = enum_type_wrapper.EnumTypeWrapper(_INFAASREQUESTSTATUSENUM)
INVALID = 0
SUCCESS = 1
UNAVAILABLE = 2



_INFAASREQUESTSTATUS = _descriptor.Descriptor(
  name='InfaasRequestStatus',
  full_name='infaas.internal.InfaasRequestStatus',
  filename=None,
  file=DESCRIPTOR,
  containing_type=None,
  fields=[
    _descriptor.FieldDescriptor(
      name='status', full_name='infaas.internal.InfaasRequestStatus.status', index=0,
      number=1, type=14, cpp_type=8, label=1,
      has_default_value=False, default_value=0,
      message_type=None, enum_type=None, containing_type=None,
      is_extension=False, extension_scope=None,
      serialized_options=None, file=DESCRIPTOR),
    _descriptor.FieldDescriptor(
      name='msg', full_name='infaas.internal.InfaasRequestStatus.msg', index=1,
      number=2, type=9, cpp_type=9, label=1,
      has_default_value=False, default_value=_b("").decode('utf-8'),
      message_type=None, enum_type=None, containing_type=None,
      is_extension=False, extension_scope=None,
      serialized_options=None, file=DESCRIPTOR),
  ],
  extensions=[
  ],
  nested_types=[],
  enum_types=[
  ],
  serialized_options=None,
  is_extendable=False,
  syntax='proto3',
  extension_ranges=[],
  oneofs=[
  ],
  serialized_start=48,
  serialized_end=140,
)

_INFAASREQUESTSTATUS.fields_by_name['status'].enum_type = _INFAASREQUESTSTATUSENUM
DESCRIPTOR.message_types_by_name['InfaasRequestStatus'] = _INFAASREQUESTSTATUS
DESCRIPTOR.enum_types_by_name['InfaasRequestStatusEnum'] = _INFAASREQUESTSTATUSENUM
_sym_db.RegisterFileDescriptor(DESCRIPTOR)

InfaasRequestStatus = _reflection.GeneratedProtocolMessageType('InfaasRequestStatus', (_message.Message,), dict(
  DESCRIPTOR = _INFAASREQUESTSTATUS,
  __module__ = 'infaas_request_status_pb2'
  # @@protoc_insertion_point(class_scope:infaas.internal.InfaasRequestStatus)
  ))
_sym_db.RegisterMessage(InfaasRequestStatus)


# @@protoc_insertion_point(module_scope)
