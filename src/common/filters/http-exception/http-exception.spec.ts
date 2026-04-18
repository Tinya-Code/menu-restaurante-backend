import { HttpException } from './http-exception';

describe('HttpException', () => {
  it('should be defined', () => {
    expect(new HttpException()).toBeDefined();
  });
});
