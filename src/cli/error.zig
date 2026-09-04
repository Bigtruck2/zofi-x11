pub const CommandError = error{ UnknownCommand, MissingSubcommand, HelpRequested };

pub const OptionError = error{
    UnknownOption,
    MissingOptionValue,
    InvalidOptionValue,
    DuplicateOption,
    ConflictingOptions,
    MissingRequiredOption,
};

pub const ArgumentError = error{
    MissingArgument,
    InvalidArgument,
};
