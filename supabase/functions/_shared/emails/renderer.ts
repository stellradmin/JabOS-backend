import React from 'npm:react@18.2.0';
import { render } from 'npm:@react-email/render@0.0.15';

export interface RenderedEmail {
  readonly html: string;
  readonly text: string;
  readonly previewText?: string;
}

export type EmailComponent<Props> = React.FC<Props>;

export function renderEmail<Props extends Record<string, unknown>>(
  Component: EmailComponent<Props>,
  props: Props,
): RenderedEmail {
  const element = React.createElement(Component, props);
  const html = render(element);
  const text = render(element, { plainText: true });
  const previewText = (props as { previewText?: string }).previewText;
  return { html, text, previewText };
}
